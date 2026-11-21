# bash's arrays, associative arrays, and process substitution.
# expect: 3 1 x
bash -c 'a=(1 2 3); declare -A m=([k]=x); n=$(wc -l < <(printf "1\n2\n3\n")); echo $n ${a[0]} ${m[k]}'
