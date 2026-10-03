// macOS class metadata binds its legacy vtable word. iOS expects that word to
// be zero. Export an absolute zero, not the address of a fabricated array.
.globl __objc_empty_vtable
.set __objc_empty_vtable, 0
