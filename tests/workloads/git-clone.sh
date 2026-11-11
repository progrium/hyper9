# git clones a local repository, which hard-links its objects.
# known: git says "hardlink different from source" for the linked objects
# expect: a
cd /tmp && git init -q -b main r && cd r
git config user.name t && git config user.email t@example.com
echo a >f && git add f && git commit -qm one
git clone -q /tmp/r /tmp/c && cat /tmp/c/f
