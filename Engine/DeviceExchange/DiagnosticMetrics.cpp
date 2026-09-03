//============================================================================================================================================
// 📦 Frontier/DeviceExchange/DiagnosticMetrics.cpp — Diagnostic Logger and Telemetry Metrics Implementation
//============================================================================================================================================

#include "DiagnosticMetrics.h"
#include <filesystem>
#include <iostream>
#include <iomanip>
#include <sstream>

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                                LIFECYCLE IMPLEMENTATION
//------------------------------------------------------------------------------------------------------------------------

DiagnosticMetrics::DiagnosticMetrics(DiagnosticConfiguration InitialConfig) noexcept
    : Config(std::move(InitialConfig))
    , TotalRecordsWritten(0)
    , InitializedCondition(false)
{
}

DiagnosticMetrics::~DiagnosticMetrics() noexcept
{
    TerminateSink();
}

bool DiagnosticMetrics::InitializeSink() noexcept
{
    try
    {
        std::filesystem::path DirectoryPath(Config.DestinationFolder.empty() ? "Diagnostics" : Config.DestinationFolder);
        if (!std::filesystem::exists(DirectoryPath))
        {
            std::filesystem::create_directories(DirectoryPath);
        }

        std::string Stem = Config.OutputFileStem.empty() ? "EngineDiagnostic" : Config.OutputFileStem;
        std::string Ext = Config.FileExtension.empty() ? ".log" : Config.FileExtension;
        if (Ext.front() != '.')
        {
            Ext = "." + Ext;
        }

        std::filesystem::path TargetPath = DirectoryPath / (Stem + Ext);
        ResolvedFilePath = TargetPath.string();

        FileStream.open(TargetPath, std::ios::out | std::ios::trunc);
        if (!FileStream.is_open())
        {
            return false;
        }

        InitializedCondition = true;

        if (Config.MarkdownTableFormatEnabled || Ext == ".md")
        {
            FileStream << "# " << Stem << " — Telemetry Log\n\n";
            FileStream << "| Timestamp | Severity | Category | Record Description |\n";
            FileStream << "|:---|:---:|:---|:---|\n";
        }
        else
        {
            FileStream << "================================================================================\n";
            FileStream << " FRONTIER ENGINE DIAGNOSTIC LOG — " << Stem << "\n";
            FileStream << "================================================================================\n";
        }

        FileStream.flush();
        return true;
    }
    catch (...)
    {
        return false;
    }
}

void DiagnosticMetrics::TerminateSink() noexcept
{
    if (InitializedCondition)
    {
        FlushSink();
        if (FileStream.is_open())
        {
            FileStream.close();
        }
        InitializedCondition = false;
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                                RECORDING OPERATIONS
//------------------------------------------------------------------------------------------------------------------------

void DiagnosticMetrics::RecordMessage(DiagnosticSeverity Severity, std::string_view CategoryToken, std::string_view MessageText) noexcept
{
    std::lock_guard<std::mutex> Lock(StreamMutex);

    std::string Timestamp = Config.TimestampPrefixEnabled ? FormulateTimestamp() : "";
    const char* SeverityStr = ConvertSeverityToString(Severity);

    if (Config.ConsoleEchoEnabled)
    {
        std::cout << "[" << SeverityStr << "] "
                  << "[" << CategoryToken << "] "
                  << MessageText << "\n";
    }

    if (!InitializedCondition || !FileStream.is_open())
    {
        return;
    }

    if (Config.MarkdownTableFormatEnabled || Config.FileExtension == ".md")
    {
        FileStream << "| " << Timestamp << " | " << SeverityStr << " | " << CategoryToken << " | " << MessageText << " |\n";
    }
    else
    {
        if (!Timestamp.empty())
        {
            FileStream << "[" << Timestamp << "] ";
        }
        FileStream << "[" << std::setw(7) << SeverityStr << "] "
                   << "[" << std::setw(16) << CategoryToken << "] "
                   << MessageText << "\n";
    }

    TotalRecordsWritten++;
    // Keep crash diagnostics durable; startup failures must not leave a header-only report.
    FileStream.flush();
    if (Config.ConsoleEchoEnabled)
    {
        std::cout.flush();
        std::cerr.flush();
    }
}

void DiagnosticMetrics::RecordMeasurement(std::string_view MeasurementToken, double NumericMagnitude, std::string_view UnitAnnotation) noexcept
{
    std::ostringstream Formatted;
    Formatted << "Measurement: " << MeasurementToken << " = " << NumericMagnitude << " [" << UnitAnnotation << "]";
    RecordMessage(DiagnosticSeverity::Information, "TelemetryMetrics", Formatted.str());
}

void DiagnosticMetrics::FlushSink() noexcept
{
    std::lock_guard<std::mutex> Lock(StreamMutex);
    if (FileStream.is_open())
    {
        FileStream.flush();
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                                FORMATTING HELPERS
//------------------------------------------------------------------------------------------------------------------------

const char* DiagnosticMetrics::ConvertSeverityToString(DiagnosticSeverity Severity) const noexcept
{
    switch (Severity)
    {
        case DiagnosticSeverity::Trace:       return "TRACE";
        case DiagnosticSeverity::Information: return "INFO";
        case DiagnosticSeverity::Warning:     return "WARN";
        case DiagnosticSeverity::Refusal:     return "REFUSE";
        case DiagnosticSeverity::Fatal:       return "FATAL";
        default:                              return "UNKNOWN";
    }
}

std::string DiagnosticMetrics::FormulateTimestamp() const noexcept
{
    auto Now = std::chrono::system_clock::now();
    auto TimeT = std::chrono::system_clock::to_time_t(Now);
    auto Millis = std::chrono::duration_cast<std::chrono::milliseconds>(Now.time_since_epoch()) % 1000;

    std::tm TimeStructure{};
#if defined(_WIN32)
    localtime_s(&TimeStructure, &TimeT);
#else
    localtime_r(&TimeT, &TimeStructure);
#endif

    std::ostringstream Stream;
    Stream << std::put_time(&TimeStructure, "%Y-%m-%d %H:%M:%S")
           << '.' << std::setfill('0') << std::setw(3) << Millis.count();
    return Stream.str();
}

} // namespace Frontier
