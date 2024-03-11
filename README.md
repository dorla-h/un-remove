## tl;dr

You want to un-remove your removed files? Now you can! Use this undo-able and perfectly POSIX unsupported extension of `rm`.

Call it Better RM, Super RM, NextGen RM, Extended RM or whatever.

## Why?

I recently killed all of my computer config (including some of my personal data such as save game data of Linux games) by accident… and I forgot making backups.

I thought about how to prevent these accidents in future. It's kind of an anti-feature to make irrevocable operations so easily accessible without a good alternative. (POSIX is very much anti-usability in my opinion.)
In my opinion, any usability respecting computer actions should be undoable for a limited time span.

Here, I Implemented a wrapper for the shell command `rm` that allows for undoing (recovering, restoring) removed files using the dual command `undo-rm`. It does not sacrifize the API of `rm` (but some of it's performance).

Of course, it can't prevent `rsync` accidents or accidents with other tools. But for accidents with `rm` (which makes almost all of the accidents or regrettable actions) this is quite useful.
`rsync` on the other hand has a dry run option and I typically use `rsync` in careful scripts rather than interactively.

I am not aware, that others made a comparable replacement (even though I am sure, many other people must have had the same idea).

## What?

This wrapper `rm` copies (and `rmm` moves) the removed files into a temporary trash directory that is located at the root of the same file system.
(Temporary in the sense that old files are cleant up after some time, based on the last data access timestamp, when new invocations of the wrapper are issued.)
The behaviour of the wrapper should be identical to `rm` (unless the DEBUG mechanism is used). I defined `delete` as a more obvious alias to the original `rm`.

It is ridiculously large and complex. I took far too much time to write this in Bash (for Bash reasons).
And performance might vary (undoing is probably slower, painfully slow to be honest).
It should be competent enough to undo removals in reversed removal order, caching arbitrary many recently removed versions.
It does not store any extra information so the behaviour is that recovered directories will recover the latest version of every original filesystem path inside.

Even better, the `rm` wrapper also warns you if you try to remove directories that could be important for you and provides a variable where a list of forbidden file paths are stored (by default the filesystem root). I added a variable that lists paths which warn you when the path is used as argument to `rm` or `rmm`.
Warned or not, all removed files and directories are catched by the temporary trash locations for another chance of life.
It also warns you, if you try to delete files from within the temporary trash directory itself.
It can distinguish between file paths inside and outside temporary trash directories and will delete files inside trash locations entirely (like if you delete files from within a Windows trash bin).

For convenience, I added `trash-rm` which only deletes files from trash without the requirement to specify the trash location in path arguments.

## How to use?

I refer to this code in my .bashrc. Make sure it only is defined for interactive shells. You may also read the code comments first.

`rm` uses the well-known API of `/usr/bin/rm` and `rmm`, an alias of `rm -m`, uses the well-known API of `/usr/bin/mv` (with target directory automatically set to the trash location).

It copes with any mix of file paths and partition-specific trash directories with only one call (which contributed to its complexity). Tip: invoke the command with a TMP_TRASH variable to change the standard trash directory basename, for example when using sudo to interact with a non-root user's trash.

The trash mechanism will only work if user-writable temporary trash directories are created in every partition (more precisely mountpoint) whose root is not writable by the user(s).
(The standrad trash directory basename can be obtained from the `tmp-trash-dir` command, it's specific to each user.)
You can easily get the associated temporary trash location by passing a arbitrary file path argument to `get-trash-dir`.

If `-f` is used, it is possible to bypass the trash mechanism (when the trash location cannot be written by the wrapper). Dry running is possible by using the DEBUG mechanism:

```bash
DEBUG=0 rm -r file1 file2 dir…
```

DEBUG mode will not turn off making copies to the trash!! (This is because the final part, moving the copies into the proper place, depends on these copies, otherwise it cannot be debugged.)
The value of `$DEBUG` selects a "breakpoint" which prints an debugging message. `0` is not assigned to any breakpoint.
However, it doesn't remove or move your files and shows an explicit preview of would-be move/remove commands.

Undoing is very simple. If you wrote `rm -r file1 file2 dir…` then you only need to write `undo-rm file1 file2 dir…` (it does not matter whether files are referenced by their original or by their trash location).
It should work as long as the files were not already deleted from trash.
Otherwise, you can also copy them manually, which however is less fun. You might then need to remove "backup suffixes" from folder and file names.
