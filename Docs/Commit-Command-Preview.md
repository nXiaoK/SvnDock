# Preview a commit command

In the commit sheet, choose **预览提交指令** before submitting. The preview
captures the currently checked paths and message, independently of the file
being inspected or the path filter. Return with **返回提交** to keep editing;
reopen the preview after changing the selection or message.

The preview uses the same target normalization and command builder as actual
selected commits. It shows the executable and arguments, working directory,
environment overrides, normalized log message sent through `/dev/stdin`, and
complete temporary targets-file contents. Filenames containing `@` retain
SVN peg escaping; paths containing line breaks remain literal argv entries.
Shell-style quoting makes special characters unambiguous.

Temporary filenames are allocated only when the process starts, so the
preview uses labelled placeholders. **复制预览** copies the complete annotated
preview, not a ready-to-run shell script. Very large previews bound on-screen
text layout, while copying retains all targets and input data.

Opening or copying the preview does not execute SVN, create targets files,
or submit changes. An empty message can be inspected but still cannot be
submitted. Actual submission rechecks local status, directory dependencies,
working-copy ownership and repository identity before running the command.
