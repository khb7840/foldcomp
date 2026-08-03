/**
 * File: database_writer.h
 * Created: 2022-12-09 14:53:33
 * Author: Milot Mirdita (milot@mirdita.de)
 */

#ifndef DATABASE_WRITER_H
#define DATABASE_WRITER_H
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>


void* make_writer(const char *data_name, const char *index_name);
void free_writer(void *reader);

bool writer_append(void *reader, const char* data, size_t length, uint32_t key, const char* name);

// Per-thread shard writers: each thread gets its own writer keyed by thread_id
void* make_shard_writer(const char *base_name, int thread_id);
void free_shard_writer(void *writer);
// flush_shard_writer writes the companion index file and frees the writer
void flush_shard_writer(void *writer);
bool shard_writer_append(void *writer, const char* data, size_t length, uint32_t key, const char* name);

// Merge shards produced by make_shard_writer into a final DB, then remove shard files
bool merge_shards(const char *base_name, int num_shards, const char *out_data, const char *out_index);

// Concatenate multiple existing DBs (data/index pairs) into one output DB
bool concat_dbs(const std::vector<std::string>& data_files,
                const std::vector<std::string>& index_files,
                const char *out_data, const char *out_index);

#endif
