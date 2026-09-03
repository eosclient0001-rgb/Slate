//============================================================================================================================================
// 📦 Frontier/DeviceExchange/WindowExchange.cpp — Cross-Platform Native Window Creation and Event Exchange (Win32 & X11)
//============================================================================================================================================

#include "WindowExchange.h"
#include <iostream>

#if defined(_WIN32)
    #ifndef WIN32_LEAN_AND_MEAN
        #define WIN32_LEAN_AND_MEAN
    #endif
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <windows.h>
#endif

#if defined(FRONTIER_ENABLE_GLFW) && __has_include(<GLFW/glfw3.h>)
    #ifndef GLFW_INCLUDE_NONE
        #define GLFW_INCLUDE_NONE
    #endif
    #include <GLFW/glfw3.h>
#elif defined(__linux__) && __has_include(<X11/Xlib.h>)
    #define FRONTIER_ENABLE_X11 1
    #include <X11/Xlib.h>
    #include <X11/Xutil.h>
    #include <X11/keysym.h>
#endif

namespace Frontier {

//------------------------------------------------------------------------------------------------------------------------
//                                                LIFECYCLE IMPLEMENTATION
//------------------------------------------------------------------------------------------------------------------------

WindowExchange::WindowExchange() noexcept
    : NativeWindowToken(nullptr)
    , NativeDisplayToken(nullptr)
    , CurrentWidth(1920)
    , CurrentHeight(1080)
    , CloseRequestedCondition(false)
    , OpenCondition(false)
{
}

WindowExchange::~WindowExchange() noexcept
{
    CloseDisplayWindow();
}

bool WindowExchange::OpenDisplayWindow(const WindowConfiguration& Config) noexcept
{
    CurrentWidth            = Config.Width;
    CurrentHeight           = Config.Height;
    CloseRequestedCondition = false;

#if defined(FRONTIER_ENABLE_GLFW) && __has_include(<GLFW/glfw3.h>)
    if (glfwInit())
    {
        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API); // For Vulkan/Native
        glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
        GLFWwindow* GlfwWin = glfwCreateWindow(
            static_cast<int>(Config.Width),
            static_cast<int>(Config.Height),
            Config.Title ? Config.Title : "Frontier Engine",
            Config.FullscreenCondition ? glfwGetPrimaryMonitor() : nullptr,
            nullptr
        );
        if (GlfwWin)
        {
            NativeWindowToken  = reinterpret_cast<void*>(GlfwWin);
            NativeDisplayToken = reinterpret_cast<void*>(0x1);
            OpenCondition      = true;
            return true;
        }
    }
#endif

#if defined(_WIN32)
    HINSTANCE InstanceHandle = GetModuleHandle(nullptr);
    NativeDisplayToken       = reinterpret_cast<void*>(InstanceHandle);

    WNDCLASSEXA WindowClass{};
    WindowClass.cbSize        = sizeof(WNDCLASSEXA);
    WindowClass.style         = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    WindowClass.lpfnWndProc   = DefWindowProcA;
    WindowClass.hInstance     = InstanceHandle;
    WindowClass.hCursor       = LoadCursor(nullptr, IDC_ARROW);
    WindowClass.lpszClassName = "FrontierWindowClass";

    RegisterClassExA(&WindowClass);

    DWORD WindowStyle = WS_OVERLAPPEDWINDOW;
    if (Config.FullscreenCondition)
    {
        WindowStyle = WS_POPUP;
    }

    RECT WindowRect{ 0, 0, static_cast<LONG>(Config.Width), static_cast<LONG>(Config.Height) };
    AdjustWindowRect(&WindowRect, WindowStyle, FALSE);

    HWND WindowHandle = CreateWindowExA(
        0,
        "FrontierWindowClass",
        Config.Title ? Config.Title : "Frontier Engine",
        WindowStyle,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        WindowRect.right - WindowRect.left,
        WindowRect.bottom - WindowRect.top,
        nullptr,
        nullptr,
        InstanceHandle,
        nullptr
    );

    if (WindowHandle != nullptr)
    {
        NativeWindowToken = reinterpret_cast<void*>(WindowHandle);
        ShowWindow(WindowHandle, SW_SHOW);
        UpdateWindow(WindowHandle);
        OpenCondition = true;
        return true;
    }

#elif defined(FRONTIER_ENABLE_X11)
    Display* XDisplay = XOpenDisplay(nullptr);
    if (XDisplay != nullptr)
    {
        NativeDisplayToken = reinterpret_cast<void*>(XDisplay);
        int ScreenNumber   = DefaultScreen(XDisplay);
        Window RootWindow  = RootWindow(XDisplay, ScreenNumber);

        Window XWindow = XCreateSimpleWindow(
            XDisplay,
            RootWindow,
            0,
            0,
            Config.Width,
            Config.Height,
            1,
            BlackPixel(XDisplay, ScreenNumber),
            WhitePixel(XDisplay, ScreenNumber)
        );

        if (XWindow != 0)
        {
            XSelectInput(XDisplay, XWindow, ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask);
            XMapWindow(XDisplay, XWindow);
            XStoreName(XDisplay, XWindow, Config.Title ? Config.Title : "Frontier Engine");
            NativeWindowToken = reinterpret_cast<void*>(static_cast<uintptr_t>(XWindow));
            OpenCondition     = true;
            return true;
        }
    }
#endif

    // Headless / Test ground virtual window fallback
    NativeWindowToken  = reinterpret_cast<void*>(0xDEADBEEFULL);
    NativeDisplayToken = reinterpret_cast<void*>(0xFEEDFACEULL);
    OpenCondition      = true;
    return true;
}

void WindowExchange::CloseDisplayWindow() noexcept
{
    if (OpenCondition)
    {
#if defined(FRONTIER_ENABLE_GLFW) && __has_include(<GLFW/glfw3.h>)
        if (NativeWindowToken != nullptr && NativeWindowToken != reinterpret_cast<void*>(0xDEADBEEFULL))
        {
            GLFWwindow* GlfwWin = reinterpret_cast<GLFWwindow*>(NativeWindowToken);
            glfwDestroyWindow(GlfwWin);
            glfwTerminate();
        }
#elif defined(_WIN32)
        if (NativeWindowToken != nullptr && NativeWindowToken != reinterpret_cast<void*>(0xDEADBEEFULL))
        {
            DestroyWindow(reinterpret_cast<HWND>(NativeWindowToken));
        }
#elif defined(FRONTIER_ENABLE_X11)
        if (NativeDisplayToken != nullptr && NativeDisplayToken != reinterpret_cast<void*>(0xFEEDFACEULL))
        {
            Display* XDisplay = reinterpret_cast<Display*>(NativeDisplayToken);
            if (NativeWindowToken != nullptr)
            {
                Window XWindow = static_cast<Window>(reinterpret_cast<uintptr_t>(NativeWindowToken));
                XDestroyWindow(XDisplay, XWindow);
            }
            XCloseDisplay(XDisplay);
        }
#endif
        NativeWindowToken       = nullptr;
        NativeDisplayToken      = nullptr;
        CloseRequestedCondition = false;
        OpenCondition           = false;
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                                EVENT POLLING
//------------------------------------------------------------------------------------------------------------------------

void WindowExchange::PollEvents(InputExchange* TargetInputExchange) noexcept
{
    (void)TargetInputExchange;
    if (!OpenCondition)
    {
        return;
    }

#if defined(FRONTIER_ENABLE_GLFW) && __has_include(<GLFW/glfw3.h>)
    if (NativeWindowToken != nullptr && NativeWindowToken != reinterpret_cast<void*>(0xDEADBEEFULL))
    {
        GLFWwindow* GlfwWin = reinterpret_cast<GLFWwindow*>(NativeWindowToken);
        if (glfwWindowShouldClose(GlfwWin))
        {
            CloseRequestedCondition = true;
        }

        glfwPollEvents();

        if (TargetInputExchange != nullptr)
        {
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyW, glfwGetKey(GlfwWin, GLFW_KEY_W) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyA, glfwGetKey(GlfwWin, GLFW_KEY_A) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyS, glfwGetKey(GlfwWin, GLFW_KEY_S) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyD, glfwGetKey(GlfwWin, GLFW_KEY_D) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyQ, glfwGetKey(GlfwWin, GLFW_KEY_Q) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyE, glfwGetKey(GlfwWin, GLFW_KEY_E) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyLeftShift, glfwGetKey(GlfwWin, GLFW_KEY_LEFT_SHIFT) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeySpace, glfwGetKey(GlfwWin, GLFW_KEY_SPACE) == GLFW_PRESS);
            TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyEscape, glfwGetKey(GlfwWin, GLFW_KEY_ESCAPE) == GLFW_PRESS);

            TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonLeft, glfwGetMouseButton(GlfwWin, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS);
            TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonRight, glfwGetMouseButton(GlfwWin, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS);
            TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonMiddle, glfwGetMouseButton(GlfwWin, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS);

            double MouseX, MouseY;
            glfwGetCursorPos(GlfwWin, &MouseX, &MouseY);
            TargetInputExchange->AssignCursorPosition(static_cast<float>(MouseX), static_cast<float>(MouseY));
        }
        return;
    }
#endif

#if defined(_WIN32)
    if (NativeWindowToken != nullptr && NativeWindowToken != reinterpret_cast<void*>(0xDEADBEEFULL))
    {
        MSG Message{};
        while (PeekMessageA(&Message, nullptr, 0, 0, PM_REMOVE))
        {
            if (Message.message == WM_QUIT || Message.message == WM_CLOSE)
            {
                CloseRequestedCondition = true;
            }

            if (TargetInputExchange != nullptr)
            {
                switch (Message.message)
                {
                    case WM_KEYDOWN:
                    case WM_KEYUP:
                    {
                        bool IsDown = (Message.message == WM_KEYDOWN);
                        switch (Message.wParam)
                        {
                            case 'W': TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyW, IsDown); break;
                            case 'A': TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyA, IsDown); break;
                            case 'S': TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyS, IsDown); break;
                            case 'D': TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyD, IsDown); break;
                            case 'Q': TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyQ, IsDown); break;
                            case 'E': TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyE, IsDown); break;
                            case VK_SHIFT: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyLeftShift, IsDown); break;
                            case VK_SPACE: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeySpace, IsDown); break;
                            case VK_ESCAPE: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyEscape, IsDown); break;
                            default: break;
                        }
                        break;
                    }
                    case WM_LBUTTONDOWN: TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonLeft, true); break;
                    case WM_LBUTTONUP:   TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonLeft, false); break;
                    case WM_RBUTTONDOWN: TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonRight, true); break;
                    case WM_RBUTTONUP:   TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonRight, false); break;
                    case WM_MOUSEWHEEL:
                    {
                        int Delta = GET_WHEEL_DELTA_WPARAM(Message.wParam);
                        TargetInputExchange->AssignMouseScroll(static_cast<float>(Delta) / 120.0f);
                        break;
                    }
                    default: break;
                }
            }

            TranslateMessage(&Message);
            DispatchMessageA(&Message);
        }
    }
#elif defined(FRONTIER_ENABLE_X11)
    if (NativeDisplayToken != nullptr && NativeDisplayToken != reinterpret_cast<void*>(0xFEEDFACEULL))
    {
        Display* XDisplay = reinterpret_cast<Display*>(NativeDisplayToken);
        while (XPending(XDisplay) > 0)
        {
            XEvent Event{};
            XNextEvent(XDisplay, &Event);

            if (Event.type == DestroyNotify)
            {
                CloseRequestedCondition = true;
            }

            if (TargetInputExchange != nullptr)
            {
                if (Event.type == KeyPress || Event.type == KeyRelease)
                {
                    bool IsDown = (Event.type == KeyPress);
                    KeySym Sym  = XLookupKeysym(&Event.xkey, 0);
                    switch (Sym)
                    {
                        case XK_w: case XK_W: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyW, IsDown); break;
                        case XK_a: case XK_A: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyA, IsDown); break;
                        case XK_s: case XK_S: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyS, IsDown); break;
                        case XK_d: case XK_D: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyD, IsDown); break;
                        case XK_q: case XK_Q: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyQ, IsDown); break;
                        case XK_e: case XK_E: TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyE, IsDown); break;
                        case XK_Shift_L:      TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyLeftShift, IsDown); break;
                        case XK_Shift_R:      TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyRightShift, IsDown); break;
                        case XK_space:        TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeySpace, IsDown); break;
                        case XK_Escape:       TargetInputExchange->AssignKeyState(VirtualKeyCategory::KeyEscape, IsDown); break;
                        default: break;
                    }
                }
                else if (Event.type == ButtonPress || Event.type == ButtonRelease)
                {
                    bool IsDown = (Event.type == ButtonPress);
                    if (Event.xbutton.button == 1) TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonLeft, IsDown);
                    else if (Event.xbutton.button == 3) TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonRight, IsDown);
                    else if (Event.xbutton.button == 2) TargetInputExchange->AssignMouseButton(MouseButtonCategory::ButtonMiddle, IsDown);
                    else if (Event.xbutton.button == 4 && IsDown) TargetInputExchange->AssignMouseScroll(1.0f);
                    else if (Event.xbutton.button == 5 && IsDown) TargetInputExchange->AssignMouseScroll(-1.0f);
                }
            }
        }
    }
#endif
}

} // namespace Frontier
