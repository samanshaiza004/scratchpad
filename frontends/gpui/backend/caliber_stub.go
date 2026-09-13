//go:build !cgo

package backend

import (
	"errors"
	"unsafe"
)

const requiredCaliberCommit = "abbe4f7"

var errNoCommand = errors.New("no pending Caliber command")

type caliberRuntime struct{}

type caliberStateLease struct {
	Revision uint64
	Schema   uint32
	Data     unsafe.Pointer
	Len      uintptr
	lease    unsafe.Pointer
}

func loadCaliber() (*caliberRuntime, error) {
	return nil, errors.New("cgo is required for the GPUI backend Caliber adapter")
}

func (c *caliberRuntime) close() {}

func (c *caliberRuntime) apiPointer() unsafe.Pointer {
	return nil
}

func (c *caliberRuntime) contextPointer() unsafe.Pointer {
	return nil
}

func (c *caliberRuntime) dispatch([]byte) error {
	return errors.New("cgo is required for Caliber dispatch")
}

func (c *caliberRuntime) takeCommand() ([]byte, error) {
	return nil, errors.New("cgo is required for Caliber command take")
}

func (c *caliberRuntime) publishState([]byte) (uint64, error) {
	return 0, errors.New("cgo is required for Caliber state publish")
}

func (c *caliberRuntime) publishResource([]byte) (uint64, uint64, error) {
	return 0, 0, errors.New("cgo is required for Caliber resource publish")
}

func (c *caliberRuntime) readResourceCopy(uint64, uint64) ([]byte, error) {
	return nil, errors.New("cgo is required for Caliber resource read")
}

func (c *caliberRuntime) releaseResourceOwner(uint64, uint64) error {
	return errors.New("cgo is required for Caliber resource release")
}

func (c *caliberRuntime) readLatestStateCopy() ([]byte, uint64, uint32, error) {
	return nil, 0, 0, errors.New("cgo is required for Caliber state read")
}

func (c *caliberRuntime) acquireLatestStateForTest() (caliberStateLease, error) {
	return caliberStateLease{}, errors.New("cgo is required for Caliber state acquire")
}

func (c *caliberRuntime) releaseStateForTest(caliberStateLease) {}
