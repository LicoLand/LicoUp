import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
export const FLUTTER_GENERATED_PLUGIN_FILES = [
  "linux/flutter/generated_plugin_registrant.cc",
  "linux/flutter/generated_plugin_registrant.h",
  "linux/flutter/generated_plugins.cmake",
  "macos/Flutter/GeneratedPluginRegistrant.swift",
  "windows/flutter/generated_plugin_registrant.cc",
  "windows/flutter/generated_plugin_registrant.h",
  "windows/flutter/generated_plugins.cmake"
];
