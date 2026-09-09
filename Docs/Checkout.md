# Check out a repository

Choose **从仓库检出…** in the sidebar, **从 SVN 仓库检出…** in the main
window's More menu, or press **⌘N**. Enter a repository URL and a full local
path. **选择父目录…** selects a parent and suggests a child directory name;
the resulting path remains editable.

Supported URL schemes are `http`, `https`, `svn`, `svn+ssh` and `file`.
Authentication and certificate trust use the installed SVN client's existing
configuration. SvnDock does not collect or save passwords. URLs containing
passwords, query parameters or fragments are rejected.

Checkout retrieves HEAD and does not expand `svn:externals`. The destination
must be new or empty, and its parent must already exist. Existing files,
symbolic-link destinations and destinations created during a download are
never overwritten. A verified download is moved into place only after SVN
finishes successfully. Failed or cancelled downloads are cleaned up from a
private temporary sibling directory.

The sheet displays elapsed time and path notifications, without inventing a
completion percentage. Cancel stops an active download; errors leave the
form available for correction and retry. After successful checkout the app
registers the working copy, selects it, and refreshes its status. If saving
succeeds but registration fails, the error identifies the saved directory;
use **添加工作副本** to register it without downloading again.
