// SPDX-License-Identifier: Apache-2.0
// Pure parser for `etcdctl member list -o simple` output. The reset helper and
// the CI harness include this same header, so both compile the shipped parser.
#ifndef MJOLNIR_MEMBER_ID_H
#define MJOLNIR_MEMBER_ID_H

#include <ctype.h>
#include <stddef.h>
#include <string.h>

static inline int member_id_contains(const char *hay, size_t len, const char *needle) {
    size_t n = strlen(needle);
    if (n == 0 || n > len) return 0;
    for (size_t i = 0; i + n <= len; i++)
        if (memcmp(hay + i, needle, n) == 0) return 1;
    return 0;
}

// `etcdctl member list -o simple` prints comma-delimited rows whose first
// column is the hex member ID. Return that ID for the row naming `self`.
static inline int member_id(const char *list, const char *self, char *out, size_t size) {
    if (!list || !self || !out || size == 0) return -1;
    const char *line = list;
    while (*line) {
        const char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        if (member_id_contains(line, len, self)) {
            const char *comma = memchr(line, ',', len);
            size_t idlen = comma ? (size_t)(comma - line) : len;
            while (idlen && (line[idlen - 1] == '\r' || line[idlen - 1] == ' ')) idlen--;
            if (idlen == 0 || idlen >= size) return -1;
            for (size_t i = 0; i < idlen; i++)
                if (!isxdigit((unsigned char)line[i])) return -1;
            memcpy(out, line, idlen);
            out[idlen] = '\0';
            return 0;
        }
        if (!nl) break;
        line = nl + 1;
    }
    return -1;
}

#endif
