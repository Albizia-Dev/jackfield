#include "include/jackfield/jackfield_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "jackfield_plugin.h"

void JackfieldPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  jackfield::JackfieldPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
