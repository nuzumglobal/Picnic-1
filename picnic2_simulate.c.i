/*! @file picnic2_impl.c
 *  @brief This is the main file of the signature scheme for the Picnic2
 *  parameter sets.
 *
 *  This file is part of the reference implementation of the Picnic signature scheme.
 *  See the accompanying documentation for complete details.
 *
 *  The code is provided under the MIT license, see LICENSE for
 *  more details.
 *  SPDX-License-Identifier: MIT
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "kdf_shake.h"
#include "macros.h"
#include "picnic_impl.h"
#include "picnic2_impl.h"
#include "picnic.h"
#include "picnic2_types.h"
#include "picnic2_tree.h"
#include "io.h"


#if defined(FN_ATTR)
FN_ATTR
#endif
static int SIM_ONLINE(uint32_t* maskedKey, shares_t* mask_shares, randomTape_t*
                          tapes, msgs_t* msgs, const uint32_t* plaintext, const uint32_t* pubKey, const picnic_instance_t* params)
{
    int ret = 0;
    uint32_t* roundKey = malloc(LOWMC_N / 8);
    uint32_t* state = malloc(LOWMC_N / 8);
    uint32_t* state2 = malloc(LOWMC_N / 8);
    uint32_t* nl_part = malloc(LOWMC_R * sizeof(uint32_t));
    shares_t* nl_part_masks = allocateShares(LOWMC_R * 32);
    shares_t* key_masks = allocateShares(LOWMC_N);    // Make a copy to use when computing each round key
    shares_t* mask2_shares = allocateShares(LOWMC_N);
    uint8_t* unopened_msgs = NULL;

    if(msgs->unopened >= 0) { //We are in verify, save the unopenend parties msgs
        unopened_msgs = malloc(params->view_size + params->input_size);
        memcpy(unopened_msgs, msgs->msgs[msgs->unopened], params->view_size + params->input_size);
    }

    copyShares(key_masks, mask_shares);

#if defined(REDUCED_ROUND_KEY_COMPUTATION)
    MPC_MUL(state, maskedKey, LOWMC_INSTANCE.k0_matrix->w64, mask_shares);       // roundKey = maskedKey * KMatrix[0]
    xor_word_array(state, state, plaintext, (LOWMC_N / 32));                                // state = plaintext + roundKey
    xor_array_RC((uint8_t*)state, (uint8_t*)state, (uint8_t*)LOWMC_INSTANCE.precomputed_constant_linear, LOWMC_N / 8);  // state = state + precomp_const
    MPC_MUL_MC(nl_part, maskedKey, LOWMC_INSTANCE.precomputed_non_linear_part_matrix->w64,
            LOWMC_INSTANCE.precomputed_constant_non_linear->w64, nl_part_masks, key_masks);
#if defined(OPTIMIZED_LINEAR_LAYER_EVALUATION)
    for (uint32_t r = 0; r < LOWMC_R-1; r++) {
        mpc_sbox(state, mask_shares, tapes, msgs, unopened_msgs, params);
        mpc_xor2_nl(state, mask_shares, state, mask_shares, nl_part, nl_part_masks, r*32+2, 30);    // state += roundKey
        MPC_MUL_Z(state2, state, mask2_shares, mask_shares, LOWMC_INSTANCE.rounds[r].z_matrix->w64);
        mpc_shuffle((uint8_t*)state, mask_shares, LOWMC_INSTANCE.rounds[r].r_mask);
        MPC_ADDMUL_R(state2, state, mask2_shares, mask_shares, LOWMC_INSTANCE.rounds[r].r_matrix->w64);
        for(uint32_t i = 0; i < 30; i++) {
            mask_shares->shares[i] = 0;
            setBit((uint8_t*)state, i, 0);
        }
        mpc_xor2(state, mask_shares, state, mask_shares, state2, mask2_shares, params);
    }
    mpc_sbox(state, mask_shares, tapes, msgs, unopened_msgs, params);
    mpc_xor2_nl(state, mask_shares, state, mask_shares, nl_part, nl_part_masks, (LOWMC_R-1)*32+2, 30);    // state += roundKey
    MPC_MUL(state, state, LOWMC_INSTANCE.zr_matrix->w64, mask_shares);              // state = state * LMatrix (r-1)
#else
    for (uint32_t r = 0; r < LOWMC_R; r++) {
        mpc_sbox(state, mask_shares, tapes, msgs, params);
        mpc_xor2_nl(state, mask_shares, state, mask_shares, nl_part, nl_part_masks, r*32+2, 30, params);    // state += roundKey
        MPC_MUL(state, state, LOWMC_INSTANCE.rounds[r].l_matrix->w64, mask_shares);              // state = state * LMatrix (r-1)
    }
#endif
#else
    MPC_MUL(roundKey, maskedKey, LOWMC_INSTANCE.k0_matrix->w64, mask_shares);       // roundKey = maskedKey * KMatrix[0]
    xor_array(state, roundKey, plaintext, (LOWMC_N / 32));                      // state = plaintext + roundKey

    shares_t* round_key_masks = allocateShares(mask_shares->numWords);
    for (uint32_t r = 0; r < LOWMC_INSTANCE.r; r++) {
        copyShares(round_key_masks, key_masks);
        MPC_MUL(roundKey, maskedKey, LOWMC_INSTANCE.rounds[r].k_matrix->w64, round_key_masks, params);

        mpc_sbox(state, mask_shares, tapes, msgs, params);
        MPC_MUL(state, state, LOWMC_INSTANCE.rounds[r].l_matrix->w64, mask_shares);              // state = state * LMatrix (r-1)
        xor_array_RC(state, state, (const uint8_t*)LOWMC_INSTANCE.rounds[r].constant->w64, LOWMC_N / 8);              // state += RConstant
        mpc_xor2(state, mask_shares, roundKey, round_key_masks, state, mask_shares, params);    // state += roundKey
    }
    freeShares(round_key_masks);
#endif

    /* Unmask the output, and check that it's correct */
    if (msgs->unopened >= 0) {
        /* During signature verification we have the shares of the output for
         * the unopened party already in msgs, but not in mask_shares. */
        for (size_t i = 0; i < LOWMC_N; i++) {
            uint8_t share = getBit(unopened_msgs, msgs->pos + i);
            setBit((uint8_t*)&mask_shares->shares[i],  msgs->unopened, share);
        }

    }
    uint32_t output[LOWMC_N / 8];
    reconstructShares(output, mask_shares);
    xor_word_array(output, output, state, (LOWMC_N / 32));

    if (memcmp(output, pubKey, LOWMC_N / 8) != 0) {
        printf("%s: output does not match pubKey\n", __func__);
        printHex("pubKey", (uint8_t*)pubKey, LOWMC_N / 8);
        printHex("output", (uint8_t*)output, LOWMC_N / 8);
        ret = -1;
        goto Exit;
    }

    broadcast(mask_shares, msgs);
    msgsTranspose(msgs);

    free(unopened_msgs);
    free(state);
    free(state2);
    free(roundKey);
    free(nl_part);
    freeShares(key_masks);
    freeShares(mask2_shares);
    freeShares(nl_part_masks);

Exit:
    return ret;
}

