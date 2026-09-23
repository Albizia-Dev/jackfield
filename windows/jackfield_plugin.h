#ifndef FLUTTER_PLUGIN_JACKFIELD_PLUGIN_H_
#define FLUTTER_PLUGIN_JACKFIELD_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace jackfield {

class JackfieldPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  JackfieldPlugin();

  virtual ~JackfieldPlugin();

  // Disallow copy and assign.
  JackfieldPlugin(const JackfieldPlugin&) = delete;
  JackfieldPlugin& operator=(const JackfieldPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace jackfield

#endif  // FLUTTER_PLUGIN_JACKFIELD_PLUGIN_H_
