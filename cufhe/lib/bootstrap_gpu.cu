/**
 * Copyright 2018 Wei Dai <wdai3141@gmail.com>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#include <include/cufhe.h>
#include <stdio.h>
#include <include/bootstrap_gpu.cuh>
#include <include/details/error_gpu.cuh>
#include <include/ntt_gpu/ntt.cuh>

#include <iostream>
using namespace std;

namespace cufhe {

using BootstrappingKeyNTT = TGSWSampleArray_T<FFP>;
BootstrappingKeyNTT* bk_ntt = nullptr;
MemoryDeleter bk_ntt_deleter = nullptr;
KeySwitchingKey* ksk_dev = nullptr;
MemoryDeleter ksk_dev_deleter = nullptr;
CuNTTHandler<>* ntt_handler = nullptr;

__global__ void __BootstrappingKeyToNTT__(BootstrappingKeyNTT bk_ntt,
                                          BootstrappingKey bk,
                                          CuNTTHandler<> ntt)
{
    __shared__ FFP sh_temp[1024];

    TGSWSample tgsw;
    bk.ExtractTGSWSample(&tgsw, blockIdx.z);
    TLWESample tlwe;
    tgsw.ExtractTLWESample(&tlwe, blockIdx.y);
    Torus* poly_in = tlwe.ExtractPoly(blockIdx.x);

    TGSWSample_T<FFP> tgsw_ntt;
    bk_ntt.ExtractTGSWSample(&tgsw_ntt, blockIdx.z);
    TLWESample_T<FFP> tlwe_ntt;
    tgsw_ntt.ExtractTLWESample(&tlwe_ntt, blockIdx.y);
    FFP* poly_out = tlwe_ntt.ExtractPoly(blockIdx.x);
    ntt.NTT<Torus>(poly_out, poly_in, sh_temp, 0);
}

void BootstrappingKeyToNTT(const BootstrappingKey* bk)
{
    BootstrappingKey* d_bk;
    d_bk = new BootstrappingKey(bk->n(), bk->k(), bk->l(), bk->w(), bk->t());
    std::pair<void*, MemoryDeleter> pair;
    pair = AllocatorGPU::New(d_bk->SizeMalloc());
    d_bk->set_data((BootstrappingKey::PointerType)pair.first);
    MemoryDeleter d_bk_deleter = pair.second;
    CuSafeCall(cudaMemcpy(d_bk->data(), bk->data(), d_bk->SizeMalloc(),
                          cudaMemcpyHostToDevice));

    Assert(bk_ntt == nullptr);
    bk_ntt =
        new BootstrappingKeyNTT(bk->n(), bk->k(), bk->l(), bk->w(), bk->t());
    pair = AllocatorGPU::New(bk_ntt->SizeMalloc());
    bk_ntt->set_data((BootstrappingKeyNTT::PointerType)pair.first);
    bk_ntt_deleter = pair.second;

    Assert(ntt_handler == nullptr);
    ntt_handler = new CuNTTHandler<>();
    ntt_handler->Create();
    ntt_handler->CreateConstant();
    cudaDeviceSynchronize();
    CuCheckError();

    dim3 grid(bk->k() + 1, (bk->k() + 1) * bk->l(), bk->t());
    dim3 block(128);
    __BootstrappingKeyToNTT__<<<grid, block>>>(*bk_ntt, *d_bk, *ntt_handler);
    cudaDeviceSynchronize();
    CuCheckError();

    d_bk_deleter(d_bk->data());
    delete d_bk;
}

void DeleteBootstrappingKeyNTT()
{
    bk_ntt_deleter(bk_ntt->data());
    delete bk_ntt;
    bk_ntt = nullptr;

    ntt_handler->Destroy();
    delete ntt_handler;
}

void KeySwitchingKeyToDevice(const KeySwitchingKey* ksk)
{
    Assert(ksk_dev == nullptr);
    ksk_dev = new KeySwitchingKey(ksk->n(), ksk->l(), ksk->w(), ksk->m());
    std::pair<void*, MemoryDeleter> pair;
    pair = AllocatorGPU::New(ksk_dev->SizeMalloc());
    ksk_dev->set_data((KeySwitchingKey::PointerType)pair.first);
    ksk_dev_deleter = pair.second;
    CuSafeCall(cudaMemcpy(ksk_dev->data(), ksk->data(), ksk->SizeMalloc(),
                          cudaMemcpyHostToDevice));
}

void DeleteKeySwitchingKey()
{
    ksk_dev_deleter(ksk_dev->data());
    delete ksk_dev;
    ksk_dev = nullptr;
}

__device__ inline uint32_t ModSwitch2048(uint32_t a)
{
    return (((uint64_t)a << 32) + (0x1UL << 52)) >> 53;
}

template <uint32_t lwe_n = 500, uint32_t tlwe_n = 1024,
          uint32_t decomp_bits = 2, uint32_t decomp_size = 8>
__device__ inline void KeySwitch(Torus* lwe, Torus* tlwe, Torus* ksk)
{
    static const Torus decomp_mask = (1u << decomp_bits) - 1;
    static const Torus decomp_offset = 1u << (31 - decomp_size * decomp_bits);
    uint32_t tid = ThisThreadRankInBlock();
    uint32_t bdim = ThisBlockSize();
    Torus tmp;
    Torus res = 0;
    Torus val = 0;
#pragma unroll 0
    for (int i = tid; i <= lwe_n; i += bdim) {
        if (i == lwe_n) res = tlwe[tlwe_n];
#pragma unroll 0
        for (int j = 0; j < tlwe_n; j++) {
            if (j == 0)
                tmp = tlwe[0];
            else
                tmp = -tlwe[1024 - j];
            tmp += decomp_offset;
            for (int k = 0; k < decomp_size; k++) {
                val = (tmp >> (32 - (k + 1) * decomp_bits)) & decomp_mask;
                if (val != 0)
                    res -= ksk[(j << 14) | (k << 11) | (val << 9) | i];
            }
        }
        lwe[i] = res;
    }
}

template <uint32_t lwe_n = 500, uint32_t tlwe_n = 1024, uint32_t tlwe_nbit = 10>
__device__ inline void RotatedTestVector(Torus* tlwe, int32_t bar, uint32_t mu)
{
    register uint32_t tid = ThisThreadRankInBlock();
    register uint32_t bdim = ThisBlockSize();
    register uint32_t cmp, neg, pos;
#pragma unroll
    for (int i = tid; i < tlwe_n; i += bdim) {
        tlwe[i] = 0;  // part a
        if (bar == 2 * tlwe_n)
            tlwe[i + tlwe_n] = mu;
        else {
            cmp = (uint32_t)(i < (bar & 1023));
            neg = -(cmp ^ (bar >> tlwe_nbit));
            pos = -((1 - cmp) ^ (bar >> tlwe_nbit));
            tlwe[i + tlwe_n] = (mu & pos) + ((-mu) & neg);  // part b
        }
    }
    __syncthreads();
}

__device__ void Accumulate(Torus* tlwe, FFP* sh_acc_ntt, FFP* sh_res_ntt,
                           uint32_t a_bar, FFP* tgsw_ntt, CuNTTHandler<> ntt)
{
    static const uint32_t decomp_bits = DEF_Bgbit;
    static const uint32_t decomp_mask = (1 << decomp_bits) - 1;
    static const int32_t decomp_half = 1 << (decomp_bits - 1);
    static const uint32_t decomp_offset =
        (0x1u << 31) + (0x1u << (31 - decomp_bits));
    uint32_t tid = ThisThreadRankInBlock();
    uint32_t bdim = ThisBlockSize();

    // temp[2] = sh_acc[2] * (x^exp - 1)
    // sh_acc_ntt[0, 1] = Decomp(temp[0])
    // sh_acc_ntt[2, 3] = Decomp(temp[1])
    // This algorithm is tested in cpp.
    Torus temp;
#pragma unroll
    for (int i = tid; i < 1024; i += bdim) {
        uint32_t cmp = (uint32_t)(i < (a_bar & 1023));
        uint32_t neg = -(cmp ^ (a_bar >> 10));
        uint32_t pos = -((1 - cmp) ^ (a_bar >> 10));
#pragma unroll
        for (int j = 0; j < 2; j++) {
            temp = tlwe[(j << 10) | ((i - a_bar) & 1023)];
            temp = (temp & pos) + ((-temp) & neg);
            temp -= tlwe[(j << 10) | i];
            // decomp temp
            temp += decomp_offset;
            sh_acc_ntt[(2 * j) * 1024 + i] = FFP(Torus(
                ((temp >> (32 - decomp_bits)) & decomp_mask) - decomp_half));
            sh_acc_ntt[(2 * j + 1) * 1024 + i] =
                FFP(Torus(((temp >> (32 - 2 * decomp_bits)) & decomp_mask) -
                          decomp_half));
        }
    }
    __syncthreads();  // must

    // 4 NTTs with 512 threads.
    // Input/output/buffer use the same shared memory location.
    if (tid < 512) {
        FFP* tar = &sh_acc_ntt[tid >> 7 << 10];
        ntt.NTT<FFP>(tar, tar, tar, tid >> 7 << 7);
    }
    else {  // must meet 4 sync made by NTTInv
        __syncthreads();
        __syncthreads();
        __syncthreads();
        __syncthreads();
    }
    __syncthreads();

// Multiply with bootstrapping key in global memory.
#pragma unroll
    for (int i = tid; i < 1024; i += bdim) {
        sh_res_ntt[4096 + i] = 0;
#pragma unroll
        for (int j = 0; j < 4; j++)
            sh_res_ntt[4096 + i] +=
                sh_acc_ntt[j * 1024 + i] * tgsw_ntt[((2 * j + 1) << 10) + i];
    }
    __syncthreads();  // new
#pragma unroll
    for (int i = tid; i < 1024; i += bdim) {
        FFP temp = 0;
#pragma unroll
        for (int j = 0; j < 4; j++)
            temp += sh_acc_ntt[j * 1024 + i] * tgsw_ntt[((2 * j) << 10) + i];
        sh_res_ntt[i] = temp;
    }
    __syncthreads();  // must

    // 2 NTTInvs and add acc with 256 threads.
    if (tid < 256) {
        FFP* src = &sh_res_ntt[tid >> 7 << 12];
        ntt.NTTInvAdd<Torus>(&tlwe[tid >> 7 << 10], src, src, tid >> 7 << 7);
    }
    else {  // must meet 4 sync made by NTTInv
        __syncthreads();
        __syncthreads();
        __syncthreads();
        __syncthreads();
    }
    __syncthreads();  // must
}

__global__ void __Bootstrap__(Torus* out, Torus* in, Torus mu, FFP* bk,
                              Torus* ksk, CuNTTHandler<> ntt)
{
    //  Assert(bk.k() == 1);
    //  Assert(bk.l() == 2);
    //  Assert(bk.n() == 1024);
    __shared__ FFP sh[6 * 1024];
    //  FFP* sh_acc_ntt[4] = { sh, sh + 1024, sh + 2048, sh + 3072 };
    //  FFP* sh_res_ntt[2] = { sh, sh + 4096 };
    Torus* tlwe = (Torus*)&sh[5120];

    // test vector
    // acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar = 2048 - ModSwitch2048(in[500]);
    register uint32_t tid = ThisThreadRankInBlock();
    register uint32_t bdim = ThisBlockSize();
    register uint32_t cmp, neg, pos;
#pragma unroll
    for (int i = tid; i < 1024; i += bdim) {
        tlwe[i] = 0;  // part a
        if (bar == 2048)
            tlwe[i + 1024] = mu;
        else {
            cmp = (uint32_t)(i < (bar & 1023));
            neg = -(cmp ^ (bar >> 10));
            pos = -((1 - cmp) ^ (bar >> 10));
            tlwe[i + 1024] = (mu & pos) + ((-mu) & neg);  // part b
        }
    }
    __syncthreads();
// accumulate
#pragma unroll
    for (int i = 0; i < 500; i++) {  // 500 iterations
        bar = ModSwitch2048(in[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }

    static const uint32_t lwe_n = 500;
    static const uint32_t tlwe_n = 1024;
    static const uint32_t ks_bits = 2;
    static const uint32_t ks_size = 8;
    KeySwitch<lwe_n, tlwe_n, ks_bits, ks_size>(out, tlwe, ksk);
}

__global__ void __NandBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                  Torus fix, FFP* bk, Torus* ksk,
                                  CuNTTHandler<> ntt)
{
    __shared__ FFP sh[(2 * DEF_l + 2) * DEF_N];  // This is V100's MAX
    // Use Last section to hold tlwe. This may to make these data in serial
    Torus* tlwe = (Torus*)&sh[(2 * DEF_l + 1) * DEF_N];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix - in0[DEF_n] - in1[DEF_n]);
    RotatedTestVector<DEF_n, DEF_Nbit>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 - in0[i] - in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __OrBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                Torus fix, FFP* bk, Torus* ksk,
                                CuNTTHandler<> ntt)
{
    __shared__ FFP sh[6 * 1024];
    Torus* tlwe = (Torus*)&sh[5120];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix + in0[DEF_n] + in1[DEF_n]);
    RotatedTestVector<DEF_n, DEF_N, DEF_Nbit>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < 500; i++) {  // 500 iterations
        bar = ModSwitch2048(0 + in0[i] + in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __OrYNBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                  Torus fix, FFP* bk, Torus* ksk,
                                  CuNTTHandler<> ntt)
{
    __shared__ FFP sh[6 * 1024];
    Torus* tlwe = (Torus*)&sh[5120];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix + in0[DEF_n] - in1[DEF_n]);
    RotatedTestVector<DEF_n, DEF_N, DEF_Nbit>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 + in0[i] - in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __OrNYBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                  Torus fix, FFP* bk, Torus* ksk,
                                  CuNTTHandler<> ntt)
{
    __shared__ FFP sh[6 * 1024];
    Torus* tlwe = (Torus*)&sh[5120];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix - in0[DEF_n] + in1[DEF_n]);
    RotatedTestVector<DEF_n, DEF_N, DEF_Nbit>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 - in0[i] + in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __AndBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                 Torus fix, FFP* bk, Torus* ksk,
                                 CuNTTHandler<> ntt)
{
    __shared__ FFP sh[(2 * DEF_l + 2) * DEF_N];  // This is V100's MAX
    Torus* tlwe = (Torus*)&sh[(2 * DEF_l + 1) * DEF_N];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix + in0[DEF_n] + in1[DEF_n]);
    RotatedTestVector<DEF_n, DEF_N, DEF_Nbit>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 + in0[i] + in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __AndYNBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                   Torus fix, FFP* bk, Torus* ksk,
                                   CuNTTHandler<> ntt)
{
    __shared__ FFP sh[(2 * DEF_l + 2) * DEF_N];  // This is V100's MAX
    Torus* tlwe = (Torus*)&sh[(2 * DEF_l + 1) * DEF_N];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix + in0[DEF_n] - in1[DEF_n]);
    RotatedTestVector<DEF_n, DEF_N, DEF_Nbit>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 + in0[i] - in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __AndNYBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                   Torus fix, FFP* bk, Torus* ksk,
                                   CuNTTHandler<> ntt)
{
    __shared__ FFP sh[(2 * DEF_l + 2) * DEF_N];  // This is V100's MAX
    Torus* tlwe = (Torus*)&sh[(2 * DEF_l + 1) * DEF_N];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix - in0[DEF_n] + in1[DEF_n]);
    RotatedTestVector<DEF_n, DEF_N, DEF_Nbit>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 - in0[i] + in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __NorBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                 Torus fix, FFP* bk, Torus* ksk,
                                 CuNTTHandler<> ntt)
{
    __shared__ FFP sh[6 * 1024];
    Torus* tlwe = (Torus*)&sh[5120];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar = 2048 - ModSwitch2048(fix - in0[500] - in1[500]);
    RotatedTestVector<DEF_n, DEF_N>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < 500; i++) {  // 500 iterations
        bar = ModSwitch2048(0 - in0[i] - in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __XorBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                 Torus fix, FFP* bk, Torus* ksk,
                                 CuNTTHandler<> ntt)
{
    __shared__ FFP sh[6 * 1024];
    Torus* tlwe = (Torus*)&sh[5120];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2048 - ModSwitch2048(fix + 2 * in0[500] + 2 * in1[500]);
    RotatedTestVector<DEF_n, DEF_N>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < 500; i++) {  // 500 iterations
        bar = ModSwitch2048(0 + 2 * in0[i] + 2 * in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __XnorBootstrap__(Torus* out, Torus* in0, Torus* in1, Torus mu,
                                  Torus fix, FFP* bk, Torus* ksk,
                                  CuNTTHandler<> ntt)
{
    __shared__ FFP sh[6 * 1024];
    Torus* tlwe = (Torus*)&sh[5120];

    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2048 - ModSwitch2048(fix - 2 * in0[500] - 2 * in1[500]);
    RotatedTestVector<DEF_n, DEF_N>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 - 2 * in0[i] - 2 * in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }
    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __NotBootstrap__(Torus* out, Torus* in, int n)
{
#pragma unroll
    for (int i = 0; i <= n; i++) {
        out[i] = -in[i];
    }
    __syncthreads();
}

// Mux(inc,in1,in0) = inc?in1:in0 = inc&in1 + (!inc)&in0
__global__ void __MuxBootstrap__(Torus* out, Torus* inc, Torus* in1, Torus* in0,
                                 Torus mu, Torus fix, Torus muxfix, FFP* bk,
                                 Torus* ksk, CuNTTHandler<> ntt)
{
    __shared__ FFP sh[(2 * DEF_l + 2) * DEF_N];  // This is V100's MAX
    // Use Last section to hold tlwe. This may to make these data in serial
    Torus* tlwe = (Torus*)&sh[(2 * DEF_l + 1) * DEF_N];
    Torus temp[DEF_N + 1];
    // test vector: acc.a = 0; acc.b = vec(mu) * x ^ (in.b()/2048)
    register int32_t bar =
        2 * DEF_N - ModSwitch2048(fix + inc[DEF_n] + in1[DEF_n]);
    register uint32_t tid = ThisThreadRankInBlock();
    register uint32_t bdim = ThisBlockSize();
    RotatedTestVector<DEF_n, DEF_N>(tlwe, bar, mu);

// accumulate
#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 + inc[i] + in1[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }

#pragma unroll
    for (int i = tid; i <= DEF_N; i += bdim) {
        temp[i] = tlwe[i];
    }

    __syncthreads();

    bar = 2 * DEF_N - ModSwitch2048(fix - inc[DEF_n] + in0[DEF_n]);

    RotatedTestVector<DEF_n, DEF_N>(tlwe, bar, mu);

#pragma unroll
    for (int i = 0; i < DEF_n; i++) {  // 500 iterations
        bar = ModSwitch2048(0 - inc[i] + in0[i]);
        Accumulate(tlwe, sh, sh, bar, bk + (i << 13), ntt);
    }

#pragma unroll
    for (int i = tid; i <= DEF_N; i += bdim) {
        tlwe[i] += temp[i];
        if (i == DEF_N) {
            tlwe[DEF_N] += muxfix;
        }
    }

    __syncthreads();

    KeySwitch<500, 1024, 2, 8>(out, tlwe, ksk);
}

__global__ void __NoiselessTrivial__(Torus* out, Torus pmu)
{
    register uint32_t tid = ThisThreadRankInBlock();
    register uint32_t bdim = ThisBlockSize();
#pragma unroll
    for (int i = tid; i <= DEF_n; i += bdim) {
        if (i == DEF_n)
            out[DEF_n] = pmu;
        else
            out[i] = 0;
    }
}

void Bootstrap(LWESample* out, LWESample* in, Torus mu, cudaStream_t st)
{
    dim3 grid(1);
    dim3 block(512);
    __Bootstrap__<<<grid, block, 0, st>>>(out->data(), in->data(), mu,
                                          bk_ntt->data(), ksk_dev->data(),
                                          *ntt_handler);
    CuCheckError();
}

void NandBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                   Torus fix, cudaStream_t st)
{
    __NandBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void OrBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                 Torus fix, cudaStream_t st)
{
    __OrBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void OrYNBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                   Torus fix, cudaStream_t st)
{
    __OrYNBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void OrNYBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                   Torus fix, cudaStream_t st)
{
    __OrNYBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void AndBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                  Torus fix, cudaStream_t st)
{
    __AndBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void AndYNBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                    Torus fix, cudaStream_t st)
{
    __AndYNBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void AndNYBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                    Torus fix, cudaStream_t st)
{
    __AndNYBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void NorBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                  Torus fix, cudaStream_t st)
{
    __NorBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void XorBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                  Torus fix, cudaStream_t st)
{
    __XorBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void XnorBootstrap(LWESample* out, LWESample* in0, LWESample* in1, Torus mu,
                   Torus fix, cudaStream_t st)
{
    __XnorBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), in0->data(), in1->data(), mu, fix, bk_ntt->data(),
        ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void NotBootstrap(LWESample* out, LWESample* in, int n, cudaStream_t st)
{
    __NotBootstrap__<<<1, DEF_N / 2, 0, st>>>(out->data(), in->data(), n);
    CuCheckError();
}

void MuxBootstrap(LWESample* out, LWESample* inc, LWESample* in1,
                  LWESample* in0, Torus mu, Torus fix, Torus muxfix,
                  cudaStream_t st)
{
    __MuxBootstrap__<<<1, DEF_N / 2, 0, st>>>(
        out->data(), inc->data(), in1->data(), in0->data(), mu, fix, muxfix,
        bk_ntt->data(), ksk_dev->data(), *ntt_handler);
    CuCheckError();
}

void NoiselessTrivial(LWESample* out, int p, Torus mu, cudaStream_t st)
{
    __NoiselessTrivial__<<<1, DEF_n + 1, 0, st>>>(out->data(), p ? mu : -mu);
}
}  // namespace cufhe