/* SPDX-License-Identifier: Apache-2.0 */
/* API 26's CRT predates the 32-byte alignment input needed for Bionic ARM TLS.
 * Retain this zero-sized constraint even when the fixture uses --gc-sections.
 */
.section .tdata.haskell_nix_tls_align,"awTR",%progbits
.p2align 5
.section .note.GNU-stack,"",%progbits
