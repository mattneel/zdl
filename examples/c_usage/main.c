#include <stdio.h>
#include <stdint.h>
#include "ffi_user.h"

int main(void) {
    FfiUser user = {
        .id = 42,
        .score = 123.5f,
    };

    for (size_t i = 0; i < sizeof user.name; i += 1) {
        user.name[i] = 0;
    }
    user.name[0] = 'a';
    user.name[1] = 'l';
    user.name[2] = 'i';
    user.name[3] = 'c';
    user.name[4] = 'e';

    size_t len = 0;
    uint8_t *bytes = ffi_user_serialize(&user, ZDL_TARGET_CPU, &len);
    if (!bytes) {
        fprintf(stderr, "serialize failed\n");
        return 1;
    }

    printf("serialized %zu bytes\n", len);

    FfiUser *decoded = ffi_user_deserialize(bytes, len);
    if (!decoded) {
        fprintf(stderr, "deserialize failed\n");
        ffi_user_free(bytes);
        return 1;
    }

    printf("id=%llu score=%.1f name=%s\n",
           (unsigned long long)decoded->id,
           decoded->score,
           (const char *)decoded->name);

    ffi_user_free(decoded);
    ffi_user_free(bytes);
    return 0;
}
