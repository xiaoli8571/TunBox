//go:build !aix && !android && !darwin && !dragonfly && !freebsd && !illumos && !ios && !linux && !netbsd && !openbsd && !solaris && !windows

package callback

// isICMPRefusal has no kernel mapping on the remaining targets; the error stays
// a normal failure there.
func isICMPRefusal(err error) bool {
	return false
}
