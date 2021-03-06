/* MIT License
 *
 * Copyright (c) 2017 Roland Singer [roland.singer@desertbit.com]
 * Copyright (c) 2020 Ilya Dmitrichenko [roland.singer@desertbit.com]
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

package main

import (
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"sync"
)

func main() {
	inDir := flag.String("d", "/data", "data directory to extact files from")
	outDir := flag.String("C", "", "output directory to extact files to") // in honour of tar

	flag.Parse()

	errs := make(chan error)

	filesWritten := 0

	copiers := make(chan func(*sync.WaitGroup, chan error), 5)

	traversingTree := sync.WaitGroup{}
	traversingTree.Add(1)
	go func() {
		doTraverseTree(*inDir, *outDir, errs, copiers)
		traversingTree.Done()
	}()

	copyingFiles := sync.WaitGroup{}
	go func() {
		copyingFiles.Add(1)
		for copier := range copiers {
			copyingFiles.Add(1)
			go copier(&copyingFiles, errs)
		}
		copyingFiles.Done()
	}()

	loggingErrors := sync.WaitGroup{}
	loggingErrors.Add(1)
	go func() {
		for err := range errs {
			if err == nil {
				filesWritten++
				continue
			}
			log.Print(err.Error())
		}
		loggingErrors.Done()
	}()

	traversingTree.Wait()
	close(copiers)
	copyingFiles.Wait()
	close(errs)
	loggingErrors.Wait()
	log.Printf("wrote %d files to %q", filesWritten, *outDir)
}

func doTraverseTree(src, dst string, errs chan error, copiers chan func(*sync.WaitGroup, chan error)) {
	src = filepath.Clean(src)
	dst = filepath.Clean(dst)

	srcInfo, err := os.Stat(src)
	if err != nil {
		errs <- fmt.Errorf("cannot stat %q: %w", src, err)
		return
	}
	if !srcInfo.IsDir() {
		errs <- fmt.Errorf("%q is not a directory", src)
		return
	}

	_, err = os.Stat(dst)
	if err != nil && !os.IsNotExist(err) {
		errs <- fmt.Errorf("cannot stat %q: %w", dst, err)
		return
	}

	err = os.MkdirAll(dst, srcInfo.Mode())
	if err != nil {
		errs <- fmt.Errorf("cannot create directory %q: %w", dst, err)
		return
	}

	entries, err := ioutil.ReadDir(src)
	if err != nil {
		errs <- fmt.Errorf("cannot list directory %q: %w", src, err)
		return
	}

	handleEntry := func(entry os.FileInfo) {
		srcPath := filepath.Join(src, entry.Name())
		dstPath := filepath.Join(dst, entry.Name())

		if entry.IsDir() {
			doTraverseTree(srcPath, dstPath, errs, copiers)
		} else {
			if entry.Mode()&os.ModeSymlink != 0 {
				srcSymlinkTarget, err := os.Readlink(srcPath)
				if err != nil {
					errs <- fmt.Errorf("cannot resolve symlink %q: %w", srcPath, err)
				}
				err = os.Symlink(srcSymlinkTarget, dstPath)
				if err != nil {
					errs <- fmt.Errorf("cannot create symlink %q: %w", dstPath, err)
				}
				log.Printf("created symlink at %q (%q)", dstPath, srcSymlinkTarget)
				return
			}

			copiers <- func(copyingFiles *sync.WaitGroup, errs chan error) {
				doCopyFile(copyingFiles, srcPath, dstPath, errs)
			}
		}
	}

	for _, entry := range entries {
		handleEntry(entry)
	}
}

func doCopyFile(wg *sync.WaitGroup, srcPath, dstPath string, errs chan error) {
	defer wg.Done()

	srcFile, err := os.Open(srcPath)
	if err != nil {
		errs <- fmt.Errorf("cannot open %q: %w", srcPath, err)
		return
	}
	defer srcFile.Close()

	srcInfo, err := srcFile.Stat()
	if err != nil {
		errs <- fmt.Errorf("cannot stat %q: %w", srcPath, err)
		return
	}

	// check if file exists, if so remove it to prvent 'text file busy' errors
	// when overwriting system binaries
	_, err = os.Stat(dstPath)
	if err != nil && !os.IsNotExist(err) {
		errs <- fmt.Errorf("cannot stat existing file %q: %w", dstPath, err)
		return
	}
	if err == nil {
		err = os.Remove(dstPath)
		if err != nil {
			errs <- fmt.Errorf("cannot remove %q: %w", dstPath, err)
			return
		}
	}

	dstFile, err := os.Create(dstPath)
	if err != nil {
		errs <- fmt.Errorf("cannot create %q: %w", dstPath, err)
		return
	}
	defer func() {
		if err := dstFile.Close(); err != nil {
			errs <- fmt.Errorf("cannot close %q: %w", dstPath, err)
			return
		}
	}()

	_, err = io.Copy(dstFile, srcFile)
	if err != nil {
		errs <- fmt.Errorf("cannot copy %q to %q: %w", srcPath, dstPath, err)
		return
	}

	err = dstFile.Sync()
	if err != nil {
		errs <- fmt.Errorf("cannot sync while copying %q to %q: %w", srcPath, dstPath, err)
		return
	}

	err = os.Chmod(dstPath, srcInfo.Mode())
	if err != nil {
		errs <- fmt.Errorf("cannot chmod %q: %w", dstPath, err)
		return
		return
	}

	log.Printf("copied %q to %q", srcPath, dstPath)
	errs <- nil
}
