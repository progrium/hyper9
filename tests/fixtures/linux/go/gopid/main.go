// Prints os.Getpid and os.Getppid, then the name and parent pid that
// /proc/<pid>/status gives for this process.
package main

import (
	"fmt"
	"os"
	"strings"
)

func main() {
	pid := os.Getpid()
	fmt.Println(pid, os.Getppid())
	status, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		fmt.Println("status:", err)
		os.Exit(1)
	}
	var name, ppid string
	for _, line := range strings.Split(string(status), "\n") {
		k, v, _ := strings.Cut(line, ":")
		switch k {
		case "Name":
			name = strings.TrimSpace(v)
		case "PPid":
			ppid = strings.TrimSpace(v)
		}
	}
	fmt.Println(name, ppid)
}
