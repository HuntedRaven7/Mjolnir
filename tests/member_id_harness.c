// SPDX-License-Identifier: Apache-2.0
// CI harness: compile the real member-id header and feed it etcdctl output.
#include "../src/member-id.h"

#include <stdio.h>

#define MAX_INPUT 16384

int main(int argc, char **argv) {
    const char *self = argc > 1 ? argv[1] : "mjolnir-1";
    char list[MAX_INPUT];
    size_t n = fread(list, 1, sizeof(list) - 1, stdin);
    list[n] = '\0';

    char id[64];
    if (member_id(list, self, id, sizeof(id)) < 0)
        puts("REJECT");
    else
        puts(id);
    return 0;
}
