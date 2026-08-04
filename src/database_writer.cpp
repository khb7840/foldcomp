/**
 * File: database_writer.cpp
 * Created: 2022-12-09 14:53:34
 * Author: Milot Mirdita (milot@mirdita.de)
 */

#include "database_writer.h"
#include "database_reader.h"

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <string>
#include <vector>

struct writer_index_s {
    uint32_t id;
    int64_t length;
    int64_t offset;
    uint32_t name_index;
};

typedef struct writer_index_s writer_index;

struct DatabaseWriter {
    FILE* data;
    FILE* index;
    FILE* lookup;
    writer_index* entries;
    std::vector<std::string> names;
    uint64_t size;
    uint64_t capacity;
    bool is_sorted;
};

void* make_writer(const char *data_name, const char *index_name) {
    DatabaseWriter* writer = new DatabaseWriter;
    writer->data = fopen(data_name, "wb");
    writer->index = fopen(index_name, "w");
    std::string lookup_name = std::string(data_name) + ".lookup";
    writer->lookup = fopen(lookup_name.c_str(), "w");
    writer->entries = (writer_index*)malloc(1000 * sizeof(writer_index));
    writer->size = 0;
    writer->capacity = 1000;
    writer->is_sorted = 1;
    // std::string source_name = std::string(data_name) + ".source";
    // FILE* source = fopen(source_name.c_str(), "w");
    // fprintf(source, "0\t%s", data_name);
    // fclose(source);
    std::string dbtype_name = std::string(data_name) + ".dbtype";
    FILE* dbtype = fopen(dbtype_name.c_str(), "w");
    // generic dbtype
    int type = 12;
    fwrite(&type, sizeof(int), 1, dbtype);
    fclose(dbtype);
    return writer;
}

void free_writer(void *writer) {
    DatabaseWriter* w = (DatabaseWriter*)writer;
    if (w->is_sorted == false) {
        std::stable_sort(w->entries, w->entries + w->size, [](const writer_index& a, const writer_index& b) { return a.id < b.id; });
    }
    for (uint64_t i = 0; i < w->size; ++i) {
        fprintf(
            w->index,
            "%" PRIu32 "\t%" PRIu64 "\t%" PRIu32 "\n",
            w->entries[i].id,
            static_cast<uint64_t>(w->entries[i].offset),
            static_cast<uint32_t>(w->entries[i].length)
        );
        fprintf(w->lookup, "%d\t%s\t0\n", w->entries[i].id, w->names[w->entries[i].name_index].c_str());
    }
    fclose(w->index);
    fclose(w->lookup);
    free(w->entries);
    fclose(w->data);
    delete w;
}

bool writer_append(void *writer, const char* data, size_t length, uint32_t key, const char* name) {
    DatabaseWriter* w = (DatabaseWriter*)writer;
    int64_t offset = ftell(w->data);
    size_t res = fwrite(data, 1, length, w->data);
    if (res != length) {
        return false;
    }
    writer_index entry;
    entry.id = key;
    entry.length = length;
    entry.offset = offset;
    w->names.push_back(name);
    entry.name_index = w->names.size() - 1;
    if (w->size == w->capacity) {
        w->capacity *= 2;
        w->entries = (writer_index*)realloc(w->entries, w->capacity * sizeof(writer_index));
    }
    w->entries[w->size] = entry;
    w->is_sorted = w->is_sorted && (w->size <= 1 || w->entries[w->size - 1].id < key);
    w->size++;
    return true;
}

// --- Per-thread shard writer ---

// A shard writer is the same DatabaseWriter but without dbtype/lookup (merged later)
struct ShardWriter {
    FILE* data;
    writer_index* entries;
    std::vector<std::string> names;
    uint64_t size;
    uint64_t capacity;
    std::string data_path;
};

static std::string shard_data_path(const char* base_name, int thread_id) {
    return std::string(base_name) + ".tmp." + std::to_string(thread_id);
}

void* make_shard_writer(const char *base_name, int thread_id) {
    ShardWriter* sw = new ShardWriter;
    sw->data_path = shard_data_path(base_name, thread_id);
    sw->data = fopen(sw->data_path.c_str(), "wb");
    if (!sw->data) {
        delete sw;
        return nullptr;
    }
    sw->entries = (writer_index*)malloc(1000 * sizeof(writer_index));
    sw->size = 0;
    sw->capacity = 1000;
    return sw;
}

void free_shard_writer(void *writer) {
    ShardWriter* sw = (ShardWriter*)writer;
    fclose(sw->data);
    free(sw->entries);
    delete sw;
}

bool shard_writer_append(void *writer, const char* data, size_t length, uint32_t key, const char* name) {
    ShardWriter* sw = (ShardWriter*)writer;
    int64_t offset = ftell(sw->data);
    size_t res = fwrite(data, 1, length, sw->data);
    if (res != length) {
        return false;
    }
    writer_index entry;
    entry.id = key;
    entry.length = length;
    entry.offset = offset;
    sw->names.push_back(name);
    entry.name_index = sw->names.size() - 1;
    if (sw->size == sw->capacity) {
        sw->capacity *= 2;
        sw->entries = (writer_index*)realloc(sw->entries, sw->capacity * sizeof(writer_index));
    }
    sw->entries[sw->size] = entry;
    sw->size++;
    return true;
}

// Merge all per-thread shards into a final DB, then remove shard temp files
bool merge_shards(const char *base_name, int num_shards, const char *out_data, const char *out_index) {
    FILE* out_data_f = fopen(out_data, "wb");
    if (!out_data_f) return false;
    FILE* out_index_f = fopen(out_index, "w");
    if (!out_index_f) { fclose(out_data_f); return false; }
    std::string lookup_name = std::string(out_data) + ".lookup";
    FILE* out_lookup_f = fopen(lookup_name.c_str(), "w");
    if (!out_lookup_f) { fclose(out_data_f); fclose(out_index_f); return false; }

    // Write dbtype
    std::string dbtype_name = std::string(out_data) + ".dbtype";
    FILE* dbtype = fopen(dbtype_name.c_str(), "w");
    int type = 12;
    fwrite(&type, sizeof(int), 1, dbtype);
    fclose(dbtype);

    int64_t global_offset = 0;
    static const size_t COPY_BUF = 1 << 20; // 1 MB
    std::vector<char> buf(COPY_BUF);

    // Collect all entries across shards for sorting
    struct MergeEntry {
        uint32_t id;
        int64_t length;
        int64_t offset; // in the merged data file
        std::string name;
    };
    std::vector<MergeEntry> all_entries;

    for (int t = 0; t < num_shards; t++) {
        std::string shard_path = shard_data_path(base_name, t);
        FILE* shard_f = fopen(shard_path.c_str(), "rb");
        if (!shard_f) continue; // shard may be empty/missing

        // Read shard index from the ShardWriter — we need to re-open it from disk.
        // The shard index is written inline in the shard file after free_shard_writer,
        // but we kept entries in memory in ShardWriter. Since merge_shards is called
        // after free_shard_writer, we need to pass data another way.
        // Solution: write a companion index file when free_shard_writer is called.
        // See: shard index file is <data_path>.index
        std::string shard_index_path = shard_path + ".index";
        FILE* shard_idx = fopen(shard_index_path.c_str(), "r");
        if (!shard_idx) { fclose(shard_f); continue; }

        // Read entries from shard index
        uint32_t id;
        int64_t off, len;
        char name_buf[4096];
        while (fscanf(shard_idx, "%" SCNu32 "\t%" SCNd64 "\t%" SCNd64 "\t%4095[^\n]\n",
                      &id, &off, &len, name_buf) == 4) {
            // Copy data for this entry
            if (fseeko(shard_f, (off_t)off, SEEK_SET) != 0) continue;
            MergeEntry me;
            me.id = id;
            me.length = len;
            me.offset = global_offset;
            me.name = name_buf;
            all_entries.push_back(me);

            int64_t remaining = len;
            while (remaining > 0) {
                size_t to_read = (size_t)std::min(remaining, (int64_t)COPY_BUF);
                size_t n = fread(buf.data(), 1, to_read, shard_f);
                if (n == 0) break;
                fwrite(buf.data(), 1, n, out_data_f);
                global_offset += (int64_t)n;
                remaining -= (int64_t)n;
            }
        }
        fclose(shard_idx);
        fclose(shard_f);

        // Remove shard files
        remove(shard_path.c_str());
        remove(shard_index_path.c_str());
    }

    // Sort by id for consistent output
    std::stable_sort(all_entries.begin(), all_entries.end(),
        [](const MergeEntry& a, const MergeEntry& b) { return a.id < b.id; });

    for (const auto& me : all_entries) {
        fprintf(out_index_f, "%" PRIu32 "\t%" PRId64 "\t%" PRId64 "\n", me.id, me.offset, me.length);
        fprintf(out_lookup_f, "%" PRIu32 "\t%s\t0\n", me.id, me.name.c_str());
    }

    fclose(out_data_f);
    fclose(out_index_f);
    fclose(out_lookup_f);
    return true;
}

// Write a companion index file for a shard so merge_shards can read it
static void write_shard_index(ShardWriter* sw) {
    std::string index_path = sw->data_path + ".index";
    FILE* f = fopen(index_path.c_str(), "w");
    if (!f) return;
    for (uint64_t i = 0; i < sw->size; i++) {
        fprintf(f, "%" PRIu32 "\t%" PRId64 "\t%" PRId64 "\t%s\n",
            sw->entries[i].id,
            sw->entries[i].offset,
            sw->entries[i].length,
            sw->names[sw->entries[i].name_index].c_str());
    }
    fclose(f);
}

// Override free_shard_writer to also flush index
void flush_shard_writer(void *writer) {
    ShardWriter* sw = (ShardWriter*)writer;
    fflush(sw->data);
    write_shard_index(sw);
    free_shard_writer(writer);
}

// Concatenate multiple existing DBs into one output DB
bool concat_dbs(const std::vector<std::string>& data_files,
                const std::vector<std::string>& index_files,
                const char *out_data, const char *out_index) {
    FILE* out_data_f = fopen(out_data, "wb");
    if (!out_data_f) return false;
    FILE* out_index_f = fopen(out_index, "w");
    if (!out_index_f) { fclose(out_data_f); return false; }
    std::string lookup_name = std::string(out_data) + ".lookup";
    FILE* out_lookup_f = fopen(lookup_name.c_str(), "w");
    if (!out_lookup_f) { fclose(out_data_f); fclose(out_index_f); return false; }

    std::string dbtype_name = std::string(out_data) + ".dbtype";
    FILE* dbtype = fopen(dbtype_name.c_str(), "w");
    int type = 12;
    fwrite(&type, sizeof(int), 1, dbtype);
    fclose(dbtype);

    static const size_t COPY_BUF = 1 << 20;
    std::vector<char> buf(COPY_BUF);
    int64_t global_offset = 0;
    uint32_t global_key = 0;

    for (size_t db = 0; db < data_files.size(); db++) {
        FILE* in_data = fopen(data_files[db].c_str(), "rb");
        if (!in_data) {
            fprintf(stderr, "[Error] Cannot open data file: %s\n", data_files[db].c_str());
            continue;
        }
        FILE* in_index = fopen(index_files[db].c_str(), "r");
        if (!in_index) {
            fprintf(stderr, "[Error] Cannot open index file: %s\n", index_files[db].c_str());
            fclose(in_data);
            continue;
        }

        // Also try to read the lookup file for names
        std::string src_lookup_path = data_files[db] + ".lookup";
        FILE* in_lookup = fopen(src_lookup_path.c_str(), "r");

        // Build a key->name map from lookup
        std::vector<std::pair<uint32_t, std::string>> lookup_map;
        if (in_lookup) {
            uint32_t lkey;
            char lname[4096];
            int lsource;
            while (fscanf(in_lookup, "%" SCNu32 "\t%4095[^\t]\t%d\n", &lkey, lname, &lsource) == 3) {
                lookup_map.push_back({lkey, std::string(lname)});
            }
            fclose(in_lookup);
            std::sort(lookup_map.begin(), lookup_map.end(),
                [](const auto& a, const auto& b) { return a.first < b.first; });
        }

        uint32_t orig_id;
        int64_t orig_off, orig_len;
        while (fscanf(in_index, "%" SCNu32 "\t%" SCNd64 "\t%" SCNd64 "\n",
                      &orig_id, &orig_off, &orig_len) == 3) {
            if (fseeko(in_data, (off_t)orig_off, SEEK_SET) != 0) continue;

            // Copy data
            int64_t remaining = orig_len;
            int64_t entry_start = global_offset;
            while (remaining > 0) {
                size_t to_read = (size_t)std::min(remaining, (int64_t)COPY_BUF);
                size_t n = fread(buf.data(), 1, to_read, in_data);
                if (n == 0) break;
                fwrite(buf.data(), 1, n, out_data_f);
                global_offset += (int64_t)n;
                remaining -= (int64_t)n;
            }

            // Find name for this key
            std::string name;
            auto it = std::lower_bound(lookup_map.begin(), lookup_map.end(), std::make_pair(orig_id, std::string()),
                [](const auto& a, const auto& b) { return a.first < b.first; });
            if (it != lookup_map.end() && it->first == orig_id) {
                name = it->second;
            } else {
                name = std::to_string(orig_id);
            }

            fprintf(out_index_f, "%" PRIu32 "\t%" PRId64 "\t%" PRId64 "\n", global_key, entry_start, orig_len);
            fprintf(out_lookup_f, "%" PRIu32 "\t%s\t0\n", global_key, name.c_str());
            global_key++;
        }

        fclose(in_data);
        fclose(in_index);
    }

    fclose(out_data_f);
    fclose(out_index_f);
    fclose(out_lookup_f);
    return true;
}
