//============================================================================================================================================
// 📦 Frontier/DeviceExchange/DiagnosticMetrics.h — Structured Diagnostic Logger and Telemetry Metrics Exporter
//============================================================================================================================================

#pragma once

#include <string>
#include <string_view>
#include <fstream>
#include <chrono>
#include <mutex>
#include <cstdint>

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                                 DIAGNOSTIC SEVERITY
//------------------------------------------------------------------------------------------------------------------------

enum class DiagnosticSeverity : uint32_t
{
    Trace                               = 0,                    // Granular execution tracking
    Information                         = 1,                    // Normal milestone telemetry
    Warning                             = 2,                    // Non-fatal domain abnormality
    Refusal                             = 3,                    // Rejected fallible transaction
    Fatal                               = 4                     // Non-recoverable termination event
};

//------------------------------------------------------------------------------------------------------------------------
//                                               DIAGNOSTIC CONFIGURATION
//------------------------------------------------------------------------------------------------------------------------

struct DiagnosticConfiguration
{
    std::string             DestinationFolder;                  // [path] target directory path (e.g. "Diagnostics" or "Logs")
    std::string             OutputFileStem;                     // [name] file stem name (e.g. "EngineTelemetry" or "RaceSession")
    std::string             FileExtension;                      // [ext] extension: ".log", ".md", ".txt", ".json", or custom
    bool                    TimestampPrefixEnabled;             // [bool] true to append ISO timestamps to log lines
    bool                    ConsoleEchoEnabled;                 // [bool] true to echo messages to stdout/stderr
    bool                    MarkdownTableFormatEnabled;         // [bool] true to format entries as markdown tables
};

//------------------------------------------------------------------------------------------------------------------------
//                                                  DIAGNOSTIC METRICS
//------------------------------------------------------------------------------------------------------------------------

class DiagnosticMetrics
{
public:
    explicit DiagnosticMetrics(DiagnosticConfiguration InitialConfig) noexcept;
    ~DiagnosticMetrics() noexcept;

    DiagnosticMetrics(const DiagnosticMetrics&) = delete;
    DiagnosticMetrics& operator=(const DiagnosticMetrics&) = delete;

    [[nodiscard]] bool      InitializeSink() noexcept;
    void                    TerminateSink() noexcept;

    void                    RecordMessage(DiagnosticSeverity Severity, std::string_view CategoryToken, std::string_view MessageText) noexcept;
    void                    RecordMeasurement(std::string_view MeasurementToken, double NumericMagnitude, std::string_view UnitAnnotation) noexcept;
    void                    FlushSink() noexcept;

    [[nodiscard]] const std::string& QueryResolvedFilePath() const noexcept { return ResolvedFilePath; }
    [[nodiscard]] size_t    QueryTotalRecordsWritten() const noexcept { return TotalRecordsWritten; }

    // Single unified conversion operator for written record count
    template<typename TargetType>
    [[nodiscard]] TargetType Convert() const noexcept;

private:
    [[nodiscard]] const char* ConvertSeverityToString(DiagnosticSeverity Severity) const noexcept;
    [[nodiscard]] std::string FormulateTimestamp() const noexcept;

    DiagnosticConfiguration Config;                             // [config] logger parameters
    std::string             ResolvedFilePath;                   // [path] final target file path
    std::ofstream           FileStream;                         // [stream] active output file stream
    std::mutex              StreamMutex;                        // [sync] multi-threaded write synchronization
    size_t                  TotalRecordsWritten;                // [count] number of recorded entries
    bool                    InitializedCondition;               // [bool] sink readiness condition
};

template<>
inline size_t DiagnosticMetrics::Convert<size_t>() const noexcept
{
    return TotalRecordsWritten;
}

template<>
inline bool DiagnosticMetrics::Convert<bool>() const noexcept
{
    return InitializedCondition;
}

} // namespace Frontier
