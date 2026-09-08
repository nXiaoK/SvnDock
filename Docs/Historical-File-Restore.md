# Restore a file to before a revision

Right-click a versioned file in SvnDock's status tree, or choose **SvnDock →
还原至指定版本前…** in Finder. Enter a positive revision number, such as `r100`
or `100`, then choose **预览还原**.
For clean files absent from the change list, right-click the working copy in
the sidebar and choose **还原文件至指定版本前…**, then select the file. The
main window’s **更多** menu also provides this file picker. The preview identifies the selected file,
its current working revision and the target revision. Confirm to restore it.

“Before r100” means the file's state at **r99**. This restores both content
and SVN properties as local changes against the existing working revision.
It does not commit to the repository or update the entire working copy.
Review the resulting diff before committing. Ordinary **还原** discards the
restoration if you decide not to keep it.

The file must exist locally, be versioned, and have no pending content or
property changes, conflicts, or add/delete schedules. Save or commit existing
work first. The target must be no newer than the file's working revision,
and the file must exist at that point in its history. SVN follows committed
copy/rename ancestry to find the historical source while retaining the local
filename. Directories, symbolic links, and files from external working copies
are not supported by this action.

Preview is read-only. Confirmation checks the local state, working revision,
repository identity and historical source again under the working-copy
operation lock. A later local edit or update invalidates the preview. Errors
and conflicts are reported without automatically retrying a mutation; inspect
the refreshed status and operation record if completion is uncertain.

Finder requests use the existing command queue and its confirmation receipts.
Repeated delivery cannot execute the same request twice, and cancelling a
revision sheet records a cancellation before processing later requests.
