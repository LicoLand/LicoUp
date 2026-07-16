import { runAdb } from "./adb.mjs";
import { missingFieldPaths, stableUniquePaths } from "../util/paths.mjs";

export function classifyAndroidAdbPhysicalDevice(adb, serial) {
  const props = {};
  const names = [
    "ro.kernel.qemu",
    "ro.boot.qemu",
    "ro.build.characteristics",
    "ro.hardware",
    "ro.boot.hardware",
    "ro.product.manufacturer",
    "ro.product.brand",
    "ro.product.model",
    "ro.product.name",
    "ro.product.device",
    "ro.build.fingerprint"
  ];
  for (const name of names) {
    const result = runAdb(adb, serial, ["shell", "getprop", name], { timeoutMs: 5_000 });
    props[name] = result.ok ? String(result.stdout || "").trim() : "";
  }
  return classifyAndroidGetpropPhysicalDevice(props);
}

export function classifyAndroidGetpropPhysicalDevice(props = {}) {
  const missing = [];
  const ambiguous = [];
  const emulatorSignals = new Set();
  const physicalSignals = new Set();
  const value = (name) => String(props[name] || "").trim().toLowerCase();
  const requiredIdentityProps = [
    "ro.build.characteristics",
    "ro.hardware",
    "ro.boot.hardware",
    "ro.product.manufacturer",
    "ro.product.brand",
    "ro.product.model",
    "ro.product.name",
    "ro.product.device",
    "ro.build.fingerprint"
  ];
  for (const name of requiredIdentityProps) {
    if (!value(name)) {
      missing.push(name);
    }
  }
  if (value("ro.kernel.qemu") === "1" || value("ro.boot.qemu") === "1") {
    emulatorSignals.add("qemu_flag");
  } else {
    physicalSignals.add("qemu_absent");
  }
  if (value("ro.build.characteristics").includes("emulator")) {
    emulatorSignals.add("emulator_characteristics");
  } else if (value("ro.build.characteristics")) {
    physicalSignals.add("non_emulator_characteristics");
  }
  if (/(?:goldfish|ranchu|qemu|vbox|emulator|cuttlefish)/u.test([
    value("ro.hardware"),
    value("ro.boot.hardware")
  ].join(" "))) {
    emulatorSignals.add("virtual_hardware");
  } else if (value("ro.hardware") || value("ro.boot.hardware")) {
    physicalSignals.add("non_virtual_hardware");
  }
  if (/(?:generic|sdk|emulator|aosp|cuttlefish|vbox)/u.test([
    value("ro.product.manufacturer"),
    value("ro.product.brand"),
    value("ro.product.model"),
    value("ro.product.name"),
    value("ro.product.device")
  ].join(" "))) {
    emulatorSignals.add("generic_sdk_product");
  }
  if (/(?:generic|sdk|emulator|aosp|cuttlefish|vbox|test-keys)/u.test(value("ro.build.fingerprint"))) {
    emulatorSignals.add("emulator_fingerprint");
  }
  const androidDeviceClass = emulatorSignals.size > 0
    ? "emulator"
    : missing.length > 0
      ? "unknown"
      : "physical";
  if (androidDeviceClass === "unknown") {
    ambiguous.push("getprop_incomplete");
  }
  return {
    androidAdbTransportAuthorized: true,
    androidDeviceClass,
    androidPhysicalDeviceProofReady: androidDeviceClass === "physical",
    androidGetpropProbeReady: missing.length === 0,
    rawGetpropIncluded: false,
    rawDeviceIdentifiersIncluded: false,
    androidEmulatorSignalCategories: [...emulatorSignals].sort(),
    androidPhysicalSignalCategories: [...physicalSignals].sort(),
    androidGetpropMissingFields: missing.sort(),
    androidGetpropAmbiguousFields: ambiguous.sort()
  };
}

export function androidPhysicalDeviceProofMissingFields(proof = {}, prefix = "device") {
  return missingFieldPaths([
    [`${prefix}.androidAdbTransportAuthorized`, proof.androidAdbTransportAuthorized === true],
    [`${prefix}.androidDeviceClass`, proof.androidDeviceClass === "physical"],
    [`${prefix}.androidPhysicalDeviceProofReady`, proof.androidPhysicalDeviceProofReady === true],
    [`${prefix}.androidGetpropProbeReady`, proof.androidGetpropProbeReady === true],
    [`${prefix}.rawGetpropIncluded`, proof.rawGetpropIncluded === false],
    [`${prefix}.rawDeviceIdentifiersIncluded`, proof.rawDeviceIdentifiersIncluded === false]
  ]);
}

export function androidPhysicalDeviceProofWeakProofFields(proof = {}, prefix = "device") {
  const fields = [];
  if (proof.rawGetpropIncluded === true) {
    fields.push(`${prefix}.rawGetpropIncluded`);
  }
  if (proof.rawDeviceIdentifiersIncluded === true) {
    fields.push(`${prefix}.rawDeviceIdentifiersIncluded`);
  }
  if (proof.androidDeviceClass === "emulator") {
    fields.push(`${prefix}.androidDeviceClass`);
  }
  if (Array.isArray(proof.androidEmulatorSignalCategories) &&
    proof.androidEmulatorSignalCategories.length > 0) {
    fields.push(`${prefix}.androidEmulatorSignalCategories`);
  }
  return stableUniquePaths(fields);
}
