// MSU Pack Maker - packs all "<game>-N.pcm" tracks into one "<game>.msp" file next to "<game>.msu".
// For the Moongom SNES MSU-1 core (Analogue Pocket, unofficial, AI-assisted fork).  GPLv3.
//
// Put MSUPackMaker.exe in the folder with your .msu / -N.pcm files and run it (double click).
// You can also drag a .msu file (or a folder) onto the exe.  The .pcm files are only read, never changed.
//
// .msp format (all u32 little endian):
//
//	4096 index entries of 8 bytes at file offset 8*N: {offset, size} of the original PCM file of track N
//	(0,0 = no such track); entry 0 holds the magic "MSUP" and the version (1).
//	The tracks follow, each is the unmodified .pcm file, starting at a multiple of 4096.
//
// The core opens the pack once and reads tracks by offset, so changing tracks needs no file open.
// Version 2: the pack is split into parts of < 2 GiB: <name>.msp (with the index), <name>.ms1, .ms2, .ms3.
// Music (tracks < 1000) is in <name>.msp, voice clips (tracks >= 1000) start in <name>.ms1.
// The top 2 bits of the size field in the index tell the part of the track; offsets are inside that part.
// At most 4 parts (about 8 GB); tracks that do not fit are left out and reported.
package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	maxTrack  = 4095
	idxBytes  = 4096 * 8
	align     = 4096
	partMax   = uint64(0x7FFFF000) // each part file stays below 2 GiB
	maxParts  = 4
	voiceFrom = 1000
	maxTrkSz  = uint64(1)<<30 - 1
)

var maxN = maxTrack

// progress prints a live percentage / speed / ETA line while the tracks are copied.
type progress struct {
	total, done uint64
	tracks, cur int
	start, last time.Time
}

func (p *progress) show(force bool) {
	now := time.Now()
	if !force && now.Sub(p.last) < 300*time.Millisecond {
		return
	}
	p.last = now
	pct := 0.0
	if p.total > 0 {
		pct = 100 * float64(p.done) / float64(p.total)
	}
	el := now.Sub(p.start).Seconds()
	speed, eta := 0.0, ""
	if el > 0.5 {
		speed = float64(p.done) / el
		if speed > 0 && p.total > p.done {
			s := int(float64(p.total-p.done) / speed)
			eta = fmt.Sprintf("  ETA %d:%02d", s/60, s%60)
		}
	}
	const w = 30
	n := int(pct / 100 * w)
	bar := strings.Repeat("#", n) + strings.Repeat(".", w-n)
	fmt.Printf("\r  [%s] %5.1f%%  %.2f/%.2f GB  track %d/%d  %.0f MB/s%s   ", bar, pct,
		float64(p.done)/1e9, float64(p.total)/1e9, p.cur, p.tracks, speed/1e6, eta)
}

type progWriter struct {
	w io.Writer
	p *progress
}

func (pw progWriter) Write(b []byte) (int, error) {
	n, err := pw.w.Write(b)
	pw.p.done += uint64(n)
	pw.p.show(false)
	return n, err
}

type trk struct {
	n    int
	path string
	size uint64
	off  uint64
	part int
}

func build(msuPath string) error {
	base := strings.TrimSuffix(msuPath, filepath.Ext(msuPath))
	dir, name := filepath.Split(base)
	var tr []trk
	pos := uint64(idxBytes)
	part := 0
	voiceStarted := false
	var skipped []int
	var total uint64
	fmt.Println("  scanning tracks (a big folder can take a while) ...")
	for n := 1; n <= maxN; n++ {
		if n%50 == 0 || n == maxN {
			fmt.Printf("\r  scanning %d / %d  (%d tracks found)   ", n, maxN, len(tr))
		}
		p := filepath.Join(dir, fmt.Sprintf("%s-%d.pcm", name, n))
		st, err := os.Stat(p)
		if err != nil || st.IsDir() {
			continue
		}
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		var h [4]byte
		_, e := io.ReadFull(f, h[:])
		f.Close()
		if e != nil || string(h[:]) != "MSU1" {
			fmt.Printf("  skip %s (not an MSU1 pcm)\n", filepath.Base(p))
			continue
		}
		sz := uint64(st.Size())
		if sz > maxTrkSz {
			skipped = append(skipped, n)
			continue
		}
		if n >= voiceFrom && !voiceStarted {
			// voice clips (tracks >= 1000) always start in their own file, separate from the music
			voiceStarted = true
			if pos > 0 && len(tr) > 0 {
				if part+1 >= maxParts {
					skipped = append(skipped, n)
					continue
				}
				part++
				pos = 0
			}
		}
		if pos+sz > partMax {
			if part+1 >= maxParts {
				skipped = append(skipped, n)
				continue
			}
			part++
			pos = 0
		}
		tr = append(tr, trk{n, p, sz, pos, part})
		total += sz
		pos += sz
		pos = (pos + align - 1) &^ (align - 1)
	}
	fmt.Println()
	if len(tr) == 0 {
		return fmt.Errorf("no %s-<N>.pcm files found", name)
	}
	idx := make([]byte, idxBytes)
	copy(idx, "MSUP")
	binary.LittleEndian.PutUint32(idx[4:], 2)
	for _, t := range tr {
		binary.LittleEndian.PutUint32(idx[t.n*8:], uint32(t.off))
		binary.LittleEndian.PutUint32(idx[t.n*8+4:], uint32(t.size)|uint32(t.part)<<30)
	}
	var total2 uint64
	prog := &progress{total: total, tracks: len(tr), start: time.Now()}
	fmt.Printf("  writing %d tracks, %.2f GB ...\n", len(tr), float64(total)/1e9)
	nparts := tr[len(tr)-1].part + 1
	for pi := 0; pi < nparts; pi++ {
		out := base + ".msp"
		if pi > 0 {
			out = fmt.Sprintf("%s.ms%d", base, pi)
		}
		f, err := os.Create(out)
		if err != nil {
			return err
		}
		w := bufio.NewWriterSize(f, 1<<20)
		cur := uint64(0)
		if pi == 0 {
			w.Write(idx)
			cur = uint64(idxBytes)
		}
		zero := make([]byte, align)
		for i, t := range tr {
			if t.part != pi {
				continue
			}
			if cur < t.off {
				w.Write(zero[:t.off-cur])
				cur = t.off
			}
			src, err := os.Open(t.path)
			if err != nil {
				f.Close()
				return err
			}
			prog.cur = i + 1
			prog.show(true)
			nw, err := io.Copy(progWriter{w, prog}, src)
			src.Close()
			if err != nil {
				f.Close()
				return err
			}
			cur += uint64(nw)
		}
		if err := w.Flush(); err != nil {
			f.Close()
			return err
		}
		f.Close()
		total2 += cur
		prog.show(true)
		fmt.Printf("\n  wrote %s  (%.2f GB)\n", filepath.Base(out), float64(cur)/1e9)
	}
	fmt.Printf("  %d tracks, %d file(s), %.2f GB in total\n", len(tr), nparts, float64(total2)/1e9)
	var nm, nv int
	var sm, sv uint64
	for _, t := range tr {
		if t.n >= voiceFrom {
			nv++
			sv += t.size
		} else {
			nm++
			sm += t.size
		}
	}
	fmt.Printf("  music (tracks 1-%d): %d tracks, %.2f GB  -> %s.msp\n", voiceFrom-1, nm, float64(sm)/1e9, name)
	fmt.Printf("  voice (tracks %d+):  %d tracks, %.2f GB  -> %s.ms1 ...\n", voiceFrom, nv, float64(sv)/1e9, name)
	// remove stale parts of an earlier, larger pack
	for pi := nparts; pi < maxParts; pi++ {
		os.Remove(fmt.Sprintf("%s.ms%d", base, pi))
	}
	if len(skipped) > 0 {
		fmt.Printf("  WARNING: %d tracks did not fit (too big, or more than 4 parts) and are NOT in the pack (first: %d)\n", len(skipped), skipped[0])
	}
	return nil
}

func findMsu(dir string) []string {
	m, _ := filepath.Glob(filepath.Join(dir, "*.msu"))
	return m
}

func main() {
	fmt.Println("MSU Pack Maker for Moongom SNES MSU-1 core")
	// Optional test aid: a file "maxtrack.txt" next to the exe with a number N packs only tracks 1..N.
	if exe, e := os.Executable(); e == nil {
		if b, e := os.ReadFile(filepath.Join(filepath.Dir(exe), "maxtrack.txt")); e == nil {
			var v int
			if _, e := fmt.Sscanf(strings.TrimSpace(string(b)), "%d", &v); e == nil && v >= 1 && v <= maxTrack {
				maxN = v
				fmt.Println("maxtrack.txt: packing only tracks 1 ..", v)
			}
		}
	}
	var files []string
	if len(os.Args) > 1 {
		for _, a := range os.Args[1:] {
			if st, err := os.Stat(a); err == nil && st.IsDir() {
				files = append(files, findMsu(a)...)
			} else {
				files = append(files, a)
			}
		}
	} else {
		dir, err := os.Getwd()
		if exe, e2 := os.Executable(); e2 == nil {
			dir = filepath.Dir(exe)
		} else if err != nil {
			dir = "."
		}
		files = findMsu(dir)
		fmt.Println("Folder:", dir)
	}
	if len(files) == 0 {
		fmt.Println("No .msu file found. Put this program in the folder that contains your .msu and -N.pcm files.")
	}
	for _, f := range files {
		fmt.Println("Game:", filepath.Base(f))
		if err := build(f); err != nil {
			fmt.Println("  error:", err)
		}
	}
	fmt.Print("\nDone. Press Enter to close.")
	bufio.NewReader(os.Stdin).ReadString('\n')
}
