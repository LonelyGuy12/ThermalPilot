package com.thermalpilot.thermal_pilot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.thermalpilot/thermal"
    private var powerManager: PowerManager? = null

    // Cached battery info from broadcast receiver
    private var cachedBatteryLevel: Int = -1
    private var cachedBatteryTemp: Double = 0.0

    // Cached thermal status from listener
    private var cachedThermalStatus: Int = 0

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_BATTERY_CHANGED) {
                val rawTemp = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0)
                cachedBatteryTemp = rawTemp / 10.0   // convert tenths-of-degree to °C
                val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
                cachedBatteryLevel = if (scale > 0) (level * 100 / scale) else level
            }
        }
    }

    // Thermal listener (API 29+)
    private val thermalListener = object : PowerManager.OnThermalStatusChangedListener {
        override fun onThermalStatusChanged(status: Int) {
            cachedThermalStatus = status
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        powerManager = getSystemService(POWER_SERVICE) as PowerManager

        // Register battery receiver
        val batteryFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        registerReceiver(batteryReceiver, batteryFilter)

        // Register thermal status listener (API 29+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            powerManager?.addThermalStatusListener(thermalListener)
            // Seed with current value
            cachedThermalStatus = powerManager?.currentThermalStatus ?: 0
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getThermalStatus" -> {
                        result.success(getThermalStatus())
                    }
                    "getBatteryInfo" -> {
                        result.success(getBatteryInfo())
                    }
                    "getCpuTopology" -> {
                        result.success(getCpuTopology())
                    }
                    "getSysfsTemps" -> {
                        result.success(getSysfsTemps())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(batteryReceiver)
        } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            powerManager?.removeThermalStatusListener(thermalListener)
        }
    }

    // ── Thermal status ──────────────────────────────────────────────────────────

    /**
     * Returns the current PowerManager thermal status (API 29+):
     *   0 = NONE, 1 = LIGHT, 2 = MODERATE, 3 = SEVERE, 4 = CRITICAL,
     *   5 = EMERGENCY, 6 = SHUTDOWN
     * Falls back to a sysfs-derived approximation if needed.
     */
    private fun getThermalStatus(): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val status = cachedThermalStatus
            // If status is 0 (NONE) try sysfs to see if device is actually warm
            if (status == 0) {
                val maxTemp = getSysfsMaxTemp()
                return when {
                    maxTemp < 0      -> 0
                    maxTemp < 55000  -> 0   // < 55 °C — COOL
                    maxTemp < 65000  -> 2   // 55-65 °C — MODERATE (WARM)
                    maxTemp < 75000  -> 3   // 65-75 °C — SEVERE (HOT)
                    else             -> 4   // > 75 °C — CRITICAL
                }
            }
            return status
        }
        // Pre-API 29: use sysfs only
        val maxTemp = getSysfsMaxTemp()
        return when {
            maxTemp < 0      -> 0
            maxTemp < 55000  -> 0
            maxTemp < 65000  -> 2
            maxTemp < 75000  -> 3
            else             -> 4
        }
    }

    // ── Battery info ────────────────────────────────────────────────────────────

    private fun getBatteryInfo(): Map<String, Any> {
        return mapOf(
            "level" to cachedBatteryLevel,
            "temperature" to cachedBatteryTemp
        )
    }

    // ── CPU topology ────────────────────────────────────────────────────────────

    /**
     * Returns CPU core indices sorted by max frequency descending (big cores first).
     * Reads /sys/devices/system/cpu/cpu{N}/cpufreq/scaling_max_freq.
     */
    private fun getCpuTopology(): List<Int> {
        data class CoreInfo(val index: Int, val maxFreq: Long)

        val cores = mutableListOf<CoreInfo>()
        val cpuDir = File("/sys/devices/system/cpu")

        try {
            val cpuDirs = cpuDir.listFiles { f ->
                f.isDirectory && f.name.matches(Regex("cpu\\d+"))
            } ?: return (0 until Runtime.getRuntime().availableProcessors()).toList()

            for (dir in cpuDirs) {
                val indexStr = dir.name.removePrefix("cpu")
                val index = indexStr.toIntOrNull() ?: continue
                val freqFile = File(dir, "cpufreq/scaling_max_freq")
                val freq = if (freqFile.canRead()) {
                    freqFile.readText().trim().toLongOrNull() ?: 0L
                } else 0L
                cores.add(CoreInfo(index, freq))
            }

            // Sort by frequency descending (big cores first), then by index for ties
            cores.sortWith(compareByDescending<CoreInfo> { it.maxFreq }.thenBy { it.index })
            return cores.map { it.index }
        } catch (e: Exception) {
            // Fallback: return 0..N-1
            return (0 until Runtime.getRuntime().availableProcessors()).toList()
        }
    }

    // ── Sysfs temps ─────────────────────────────────────────────────────────────

    /**
     * Returns a map of thermal zone name → temperature in milli-°C.
     * Many devices block this on API 30+ — caller must handle empty map.
     */
    private fun getSysfsTemps(): Map<String, Int> {
        val result = mutableMapOf<String, Int>()
        try {
            val thermalDir = File("/sys/class/thermal")
            if (!thermalDir.exists()) return result

            val zones = thermalDir.listFiles { f ->
                f.isDirectory && f.name.startsWith("thermal_zone")
            } ?: return result

            for (zone in zones) {
                val tempFile = File(zone, "temp")
                val typeFile = File(zone, "type")
                if (!tempFile.canRead()) continue
                val temp = tempFile.readText().trim().toIntOrNull() ?: continue
                val type = if (typeFile.canRead()) typeFile.readText().trim() else zone.name
                result[type] = temp
            }
        } catch (_: Exception) {}
        return result
    }

    /**
     * Returns the maximum temperature found in sysfs (milli-°C), or -1 on failure.
     */
    private fun getSysfsMaxTemp(): Int {
        return try {
            val thermalDir = File("/sys/class/thermal")
            if (!thermalDir.exists()) return -1
            val zones = thermalDir.listFiles { f ->
                f.isDirectory && f.name.startsWith("thermal_zone")
            } ?: return -1
            zones.mapNotNull { zone ->
                val f = File(zone, "temp")
                if (f.canRead()) f.readText().trim().toIntOrNull() else null
            }.maxOrNull() ?: -1
        } catch (_: Exception) {
            -1
        }
    }
}
