package main

import (
	"bufio"
	"io"
	"os"
	"os/exec"
	"sync"
)

// The real launcher: children are ordinary OS processes. Their
// stdout/stderr are scanned line by line (the engines' own
// protocols are all line-shaped); overlong lines are truncated
// so a runaway child cannot flood the pipe.

const maxLine = 8192

type execLauncher struct{}

func (execLauncher) Launch(spec procSpec) (child, error) {
	cmd := exec.Command(spec.Exe, spec.Args...)
	if spec.WorkDir != "" {
		cmd.Dir = spec.WorkDir
	}
	env := os.Environ()
	for k, v := range spec.Env {
		env = append(env, k+"="+v)
	}
	cmd.Env = env
	var stdin io.WriteCloser
	var err error
	if spec.Stdin {
		si, err := cmd.StdinPipe()
		if err != nil {
			return nil, err
		}
		stdin = si
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	c := &execChild{cmd: cmd, stdin: stdin, lines: make(chan childLine, 128)}
	var wg sync.WaitGroup
	wg.Add(2)
	go scanLines(stdout, "stdout", c.lines, &wg)
	go scanLines(stderr, "stderr", c.lines, &wg)
	go func() {
		wg.Wait()
		close(c.lines)
	}()
	return c, nil
}

func scanLines(r io.Reader, stream string, out chan<- childLine, wg *sync.WaitGroup) {
	defer wg.Done()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 4096), maxLine+1024)
	for sc.Scan() {
		line := sc.Text()
		if len(line) > maxLine {
			line = line[:maxLine] + "…"
		}
		out <- childLine{Stream: stream, Line: line}
	}
}

type execChild struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	lines chan childLine
	wmu   sync.Mutex
}

func (c *execChild) PID() int { return c.cmd.Process.Pid }

func (c *execChild) Lines() <-chan childLine { return c.lines }

func (c *execChild) WriteLine(s string) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.stdin == nil {
		return io.ErrClosedPipe
	}
	_, err := io.WriteString(c.stdin, s+"\n")
	return err
}

func (c *execChild) CloseStdin() error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.stdin == nil {
		return nil
	}
	err := c.stdin.Close()
	c.stdin = nil
	return err
}

func (c *execChild) Kill() error {
	if c.cmd.Process == nil {
		return nil
	}
	return c.cmd.Process.Kill()
}

func (c *execChild) Wait() (int, error) {
	err := c.cmd.Wait()
	if err == nil {
		return 0, nil
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode(), nil
	}
	return -1, err
}
