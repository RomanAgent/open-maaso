mergeInto(LibraryManager.library, {
  MaasoUnityAvatarReady: function () {
    var canvas = Module.canvas;
    if (!canvas) {
      return;
    }
    canvas.dispatchEvent(new CustomEvent("maaso-unity-avatar-ready"));
  },

  MaasoUnityAvatarCommandResult: function (payloadPointer) {
    var canvas = Module.canvas;
    if (!canvas) {
      return;
    }
    var payload = payloadPointer ? UTF8ToString(payloadPointer) : "";
    canvas.dispatchEvent(new CustomEvent(
      "maaso-unity-avatar-command-result",
      { detail: payload }
    ));
  },

  MaasoUnityAvatarWorldEvent: function (payloadPointer) {
    var canvas = Module.canvas;
    if (!canvas) {
      return;
    }
    var payload = payloadPointer ? UTF8ToString(payloadPointer) : "";
    canvas.dispatchEvent(new CustomEvent(
      "maaso-unity-avatar-world-event",
      { detail: payload }
    ));
  },
});
