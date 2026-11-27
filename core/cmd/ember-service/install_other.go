//go:build !windows

package main

import "fmt"

func runInstall() int {
	fmt.Println("install is Windows-only")
	return 2
}

func runUninstall() int {
	fmt.Println("uninstall is Windows-only")
	return 2
}
