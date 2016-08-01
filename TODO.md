# TODO

## Features, bug fixes, nitpicks etc.

Find duplicate table names in S3 bucket and warn.

Ask twice for password when password for create_user is entered on the commandline.

Enable syncing local files with S3 (to remove files that no longer exist locally).


Allow to specify which group has access to any source.  (Goal: differentiate users of ETL, full read-only analytics groups)

Query the data base for the existence of a user's schema or the current search path instead of relying on args.

Warn if distribution key is not also a sort key.

Test whether relation is table or view to invoke the correct drop command.  (When switching from VIEW to CTAS
(or back) the --drop option breaks.)

When loading data from upstream, cut off at midnight NY?

For common failure patterns in table designs, provide hints beyond error messages.

Add checks for partitions to have correct size after download (count rows while partitioning?)