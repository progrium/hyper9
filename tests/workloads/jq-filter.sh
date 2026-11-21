# jq over a small document.
# expect: 6
# expect: "b"
echo '{"a": [1, 2, 3], "k": {"b": 1}}' | jq '.a | add'
echo '{"k": {"b": 1}}' | jq '.k | keys[0]'
