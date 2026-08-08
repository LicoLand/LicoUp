import { runCommand } from "./adb.mjs";
import { classifyAndroidAdbPhysicalDevice } from "./classify.mjs";

export function pickDevice(adb, options) {
  const result = runCommand(adb, ["devices"]);
  if (!result.ok) {
    throw new Error("adb devices failed");
  }
  const devices = result.stdout
    .split(/\r?\n/)
    .slice(1)
    .map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => serial && state === "device")
    .map(([serial]) => serial);
  if (devices.length === 0) {
    throw new Error("no authorized Android device is connected");
  }
  if (options.serial) {
    if (!devices.includes(options.serial)) {
      throw new Error("configured Android device is not authorized");
    }
    return {
      serial: options.serial,
      authorizedDeviceCount: devices.length,
      physicalProof: classifyAndroidAdbPhysicalDevice(adb, options.serial)
    };
  }
  if (devices.length > 1) {
    throw new Error("multiple Android devices are connected; configure a device id");
  }
  return {
    serial: devices[0],
    authorizedDeviceCount: devices.length,
    physicalProof: classifyAndroidAdbPhysicalDevice(adb, devices[0])
  };
}
