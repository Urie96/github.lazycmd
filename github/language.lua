local file = require 'file'

local M = {}

local language_to_filename = {
  Rust = 'main.rs',
  Lua = 'init.lua',
  Go = 'main.go',
  Python = 'main.py',
  JavaScript = 'index.js',
  TypeScript = 'index.ts',
  TSX = 'index.tsx',
  JSX = 'index.jsx',
  Shell = 'script.sh',
  Bash = 'script.sh',
  Zsh = 'script.sh',
  Fish = 'script.fish',
  PowerShell = 'script.ps1',
  Zig = 'main.zig',
  Nix = 'default.nix',
  C = 'main.c',
  ['C++'] = 'main.cpp',
  ['C#'] = 'main.cs',
  ['F#'] = 'main.fs',
  ['Objective-C'] = 'main.m',
  ['Objective-C++'] = 'main.mm',
  Java = 'Main.java',
  Kotlin = 'Main.kt',
  Swift = 'main.swift',
  PHP = 'index.php',
  Ruby = 'main.rb',
  Haskell = 'main.hs',
  Elixir = 'main.ex',
  Erlang = 'main.erl',
  OCaml = 'main.ml',
  Dart = 'main.dart',
  R = 'main.r',
  Scala = 'Main.scala',
  Perl = 'main.pl',
  ['Vim Script'] = 'plugin.vim',
  Clojure = 'core.clj',
  HCL = 'main.tf',
  Astro = 'index.astro',
  HTML = 'index.html',
  CSS = 'style.css',
  SCSS = 'style.scss',
  Vue = 'App.vue',
  Svelte = 'App.svelte',
  Dockerfile = 'Dockerfile',
  Makefile = 'Makefile',
  Markdown = 'README.md',
  JSON = 'package.json',
  YAML = 'config.yaml',
  Toml = 'Cargo.toml',
  TOML = 'Cargo.toml',
}

function M.filename_for(language)
  return language_to_filename[tostring(language or '')]
end

function M.syntax_from_filename(filename)
  local name = tostring(filename or ''):lower()
  if name == 'dockerfile' then return 'dockerfile' end
  return name:match '%.([^.]+)$'
end

function M.syntax(filename)
  return M.syntax_from_filename(filename) or 'text'
end

function M.style(language)
  local sample = M.filename_for(language)
  if sample and sample ~= '' then
    local icon, color = file.get_icon(sample)
    if icon and icon ~= '' then return { icon = icon, color = color or 'darkgray' } end
  end

  return { icon = '󰈔', color = 'darkgray' }
end

function M.file_style(name)
  local icon, color = file.get_icon(name)
  return {
    icon = icon or '󰈔',
    color = color or 'white',
  }
end

return M
