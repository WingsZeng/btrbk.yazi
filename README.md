# btrbk.yazi

Browse [btrbk](https://digint.ch/btrbk/) snapshots of the current directory in
[Yazi](https://yazi-rs.github.io). Pick a snapshot with fzf and the **same
relative directory** inside it opens in a new tab, so you can copy files out
and paste them back in the original tab.

No sudo, polkit or extra permissions — only read access to the snapshot
directory.

## Requirements

- Yazi ≥ 26.9.1
- `btrbk`, `fzf`, `findmnt` (util-linux), `realpath` (coreutils)
- btrbk configs in `/etc/btrbk/*.conf`, with snapshots readable by your user

## Install

```sh
ya pkg add WingsZeng/btrbk
```

Or clone/symlink this repository to `~/.config/yazi/plugins/btrbk.yazi`.

## Usage

`~/.config/yazi/keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = ["g", "b"]
run  = "plugin btrbk"
desc = "Browse btrbk snapshots of this directory"
```

The picker is plain fzf (your `FZF_DEFAULT_OPTS` apply), newest snapshot
first, with an `ls` preview of the target directory. `Enter` opens it in a
new tab.

## How it works

1. Snapshot configs come from `btrbk -c <conf> --lockfile=/dev/null --format=raw list config`
   for every `/etc/btrbk/*.conf` — btrbk resolves `volume`/`snapshot_dir`
   itself, nothing is parsed by hand. Remote sources are ignored.
2. The current directory, each `source_subvolume` and each `snapshot_path`
   are canonicalized and located with `findmnt`
   (`FSROOT` + path below `TARGET`, plus `MAJ:MIN`). This handles subvolumes
   mounted anywhere, bind mounts, and several btrfs filesystems with the same
   subvolume names.
3. The longest configured subvolume containing the current directory wins
   (path-component boundaries, so `/home2` is not under `/home`).
4. Snapshots are the directories `<snapshot_name>.<timestamp>` in
   `snapshot_path`, sorted by name descending. Only those that contain the
   relative directory (as a real directory, symlinks are not followed) are
   listed.

Every failure is reported with a notification instead of falling back to the
snapshot root: not on btrfs, `findmnt`/`btrbk` errors, no matching config,
missing subvolume or snapshot directory, no snapshots, no snapshot containing
the current directory, or already inside a snapshot directory.

## Limitations

- btrfs snapshots are not recursive: a nested subvolume that btrbk does not
  snapshot separately appears as an empty directory in the snapshot.
