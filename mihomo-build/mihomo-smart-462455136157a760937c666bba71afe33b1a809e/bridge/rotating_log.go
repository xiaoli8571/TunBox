package bridge

import (
	"io"
	"os"
	"strconv"
)

// RotatingLog is written by a single collector goroutine, never by the UI thread.
// Rotation keeps the newest evidence without allowing an error storm to fill disk.
type RotatingLog struct {
	Path     string
	MaxBytes int64
	Backups  int
}

func (w *RotatingLog) Write(p []byte) (int, error) {
	if w.MaxBytes <= 0 || w.Backups < 1 {
		return 0, os.ErrInvalid
	}
	if int64(len(p)) > w.MaxBytes {
		original := len(p)
		_, err := w.Write(p[len(p)-int(w.MaxBytes):])
		if err != nil {
			return 0, err
		}
		return original, nil
	}
	if info, err := os.Stat(w.Path); err == nil && info.Size()+int64(len(p)) > w.MaxBytes {
		_ = os.Remove(w.Path + "." + strconv.Itoa(w.Backups))
		for i := w.Backups - 1; i >= 1; i-- {
			_ = os.Rename(w.Path+"."+strconv.Itoa(i), w.Path+"."+strconv.Itoa(i+1))
		}
		if err := os.Rename(w.Path, w.Path+".1"); err != nil {
			return 0, err
		}
	}
	f, err := os.OpenFile(w.Path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return f.Write(p)
}

// Disk errors must not close the stdout pipe and break/block the core's logging.
type BestEffortLog struct{ Writer io.Writer }

func (w BestEffortLog) Write(p []byte) (int, error) { _, _ = w.Writer.Write(p); return len(p), nil }
