# git in a fresh repository: commits, a branch, a merge, and the log.
# expect: 4
# expect: b
cd /tmp && git init -q -b main r && cd r
git config user.name t && git config user.email t@example.com
echo a >f && git add f && git commit -qm one
git checkout -q -b side && echo b >g && git add g && git commit -qm two
git checkout -q main && echo c >>f && git commit -qam three
git merge -q --no-edit side && git log --oneline | wc -l | tr -d " "
cat g
