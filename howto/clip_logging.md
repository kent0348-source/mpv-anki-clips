# Clip logging

When `clip_log_enabled=yes`, completed logged jobs are written as structured JSON records. The shipped core settings example enables clip logging. The log base directory is `clip_log_save_dir` when set; otherwise it is a `clip_logs` directory beside the script folder.

Each log set contains:

- One detailed JSON record per job under `records/<YYYY-MM>/`.
- An `index.json` summary entry for each record.

Records include the source and output paths, clip timing, output size, encode command arguments, loudnorm details, export field values, Anki deck/model/note identifiers when available, active profile, and export/update context. `log_type` is `mpv_anki_clips`. Setting `clip_log_advanced_encode_logging=yes` adds deeper encode-process detail when available.

## Duplicate handling and retention

The logger checks index entries from the same source path for time overlap. If the overlap is at least `clip_log_duplicate_overlap_percent` of either clip's own duration, the prior entry is treated as a duplicate: its summary is removed, its record file is deleted when the path is known, and the new record lists the replaced ID in `replaced_duplicate_record_ids`.

There is no age-based retention or maximum-entry cap. Records are removed only through duplicate replacement or when the index is pruned because a referenced record file is missing.

## Changing the log directory

Changing `clip_log_save_dir` does not move or copy the old log set. The new directory is used from then on; an existing valid `index.json` and `records/` set there is reused, and its entries participate in duplicate checks.

If the new directory has no `index.json`, the logger creates a new one. It does not import orphaned record files in that case. If `index.json` is malformed, the logger attempts recovery: it backs up the malformed index with a timestamped `.bak` suffix, scans `records/<YYYY-MM>/` for valid JSON records, and rebuilds the index from those records. Invalid record files are skipped with a warning. Missing record files referenced by an otherwise valid index are pruned on load.

Keep a separate backup if the logs are important; changing the configured location is not a migration or retention mechanism.
