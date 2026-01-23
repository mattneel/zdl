/**
 * zdl C API Query Example
 *
 * Demonstrates the query API for filtering and iterating over serialized data.
 * Compile with: gcc -I../../zig-out/include -L../../zig-out/lib -lzdl main.c -o query_example
 * Run with: LD_LIBRARY_PATH=../../zig-out/lib ./query_example
 */

#include <stdio.h>
#include <string.h>
#include "ffi_user.h"

void print_user(const FfiUser *user) {
    printf("  id=%llu score=%.1f name=%.32s\n",
           (unsigned long long)user->id,
           user->score,
           (const char *)user->name);
}

int main(void) {
    printf("=== zdl Query API Example ===\n\n");

    // Create test data
    FfiUser users[5];
    memset(users, 0, sizeof(users));

    const char *names[] = {"alice", "bob", "charlie", "diana", "eve"};
    float scores[] = {85.5f, 92.0f, 78.5f, 95.0f, 88.0f};

    for (int i = 0; i < 5; i++) {
        users[i].id = i + 1;
        users[i].score = scores[i];
        strncpy((char *)users[i].name, names[i], sizeof(users[i].name) - 1);
    }

    // Serialize array
    size_t len = 0;
    uint8_t *bytes = ffi_user_serialize_array(users, 5, ZDL_TARGET_CPU, &len);
    if (!bytes) {
        fprintf(stderr, "serialize_array failed: %s\n", zdl_error_message(zdl_last_error()));
        return 1;
    }
    printf("Serialized %zu bytes containing %llu users\n\n",
           len, (unsigned long long)ffi_user_array_count(bytes, len));

    // --- Query with filter ---
    printf("Query: users with score >= 85\n");
    struct ffi_user_query *q = ffi_user_query_new(bytes, len);
    if (!q) {
        fprintf(stderr, "query_new failed: %s\n", zdl_error_message(zdl_last_error()));
        ffi_user_free(bytes);
        return 1;
    }

    // Add filter: score >= 85
    zdl_error_t err = ffi_user_query_filter_f32(q, "score", ZDL_GE, 85.0f);
    if (err != ZDL_OK) {
        fprintf(stderr, "filter failed: %s\n", zdl_error_message(err));
        ffi_user_query_free(q);
        ffi_user_free(bytes);
        return 1;
    }

    // Set limit (required for collect)
    ffi_user_query_limit(q, 100);

    // Collect results
    size_t count = 0;
    FfiUser *results = ffi_user_query_collect(q, &count);
    printf("Found %zu matching users:\n", count);
    for (size_t i = 0; i < count; i++) {
        print_user(&results[i]);
    }
    ffi_user_free(results);
    ffi_user_query_free(q);

    // --- Query with iterator ---
    printf("\nQuery (iterator): users with id > 2\n");
    q = ffi_user_query_new(bytes, len);
    ffi_user_query_filter_u64(q, "id", ZDL_GT, 2);

    // Use iterator instead of collect
    err = ffi_user_query_iter_start(q);
    if (err != ZDL_OK) {
        fprintf(stderr, "iter_start failed: %s\n", zdl_error_message(err));
        ffi_user_query_free(q);
        ffi_user_free(bytes);
        return 1;
    }

    const FfiUser *item;
    while ((item = ffi_user_query_iter_next(q)) != NULL) {
        print_user(item);
    }
    ffi_user_query_free(q);

    // --- Count without collecting ---
    printf("\nQuery count: users with score < 90\n");
    q = ffi_user_query_new(bytes, len);
    ffi_user_query_filter_f32(q, "score", ZDL_LT, 90.0f);
    uint64_t n = ffi_user_query_count(q);
    printf("Count: %llu users\n", (unsigned long long)n);
    ffi_user_query_free(q);

    // --- Introspection ---
    printf("\n=== Introspection ===\n");
    printf("Struct size: %zu bytes\n", ffi_user_struct_size());
    printf("Field count: %zu\n", ffi_user_field_count());

    for (size_t i = 0; i < ffi_user_field_count(); i++) {
        const zdl_field_info_t *info = ffi_user_field_info(i);
        if (info) {
            printf("  [%zu] %s: type=%d offset=%zu size=%zu array_len=%zu\n",
                   i, info->name, info->type, info->offset, info->size, info->array_len);
        }
    }

    // Lookup by name
    const zdl_field_info_t *score_info = ffi_user_field_by_name("score");
    if (score_info) {
        printf("\nLookup 'score': offset=%zu size=%zu\n", score_info->offset, score_info->size);
    }

    // Cleanup
    ffi_user_free(bytes);
    printf("\nDone!\n");
    return 0;
}
