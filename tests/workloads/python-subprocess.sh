# Python's subprocess, with captured output, which needs poll and pipes.
# expect: b'sub\n'
python3 -c 'import subprocess; print(subprocess.run(["echo", "sub"], capture_output=True).stdout)'
