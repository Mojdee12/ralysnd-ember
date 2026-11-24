package com.ralysnd.ember

/**
 * The Sudoku sidecar engine (build 2127, H2): Hiddify's
 * sing-box fork built with its with_sudoku tag — the only
 * engine anywhere in the app that speaks Sudoku, a
 * protocol that exists solely in that fork. Built from
 * the pinned fork source staged in engines/sudokubox/
 * (see PROVENANCE.md there) and staged in jniLibs as
 * libsudokubox.so. A separate binary from libsingbox.so
 * on purpose: the official sing-box the other sidecar
 * profiles ride stays byte-identical, and this fork's
 * ~66 MB costs nothing until a Sudoku profile connects.
 *
 * Shape mirrors SingBoxCore exactly: one mixed inbound
 * on [PORT], the profile's sudoku outbound, and the Xray
 * tunnel's proxy outbound is a plain SOCKS outbound
 * aimed at that port. The Dart side writes the generated
 * config to filesDir/sudokubox/config.json and passes
 * `run -c <path>`.
 */
object SudokuBoxCore : SubprocessCore(
    libName = "libsudokubox.so",
    dirName = "sudokubox",
    port = 20865,
    tcpProbe = true,
    label = "Sudoku engine",
) {
    /** The fixed local mixed-inbound port (mirrored in
     *  Dart: sudokuListenPort in sudoku_config.dart). */
    const val PORT = 20865
}
