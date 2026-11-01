using UnityEngine;

namespace Maaso.Avatar
{
#if UNITY_WEBGL && !UNITY_EDITOR
    [DefaultExecutionOrder(32000)]
    internal sealed class WebGLTransparentCameraHook : MonoBehaviour
    {
        private Camera targetCamera;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
            if (FindAnyObjectByType<WebGLTransparentCameraHook>() != null)
            {
                return;
            }

            var hookObject = new GameObject("Maaso WebGL Transparent Camera Hook");
            DontDestroyOnLoad(hookObject);
            hookObject.AddComponent<WebGLTransparentCameraHook>();
        }

        private void LateUpdate()
        {
            if (targetCamera == null)
            {
                targetCamera = Camera.main;
            }
            if (targetCamera == null)
            {
                return;
            }

            targetCamera.clearFlags = CameraClearFlags.SolidColor;
            targetCamera.allowHDR = false;
            Color background = targetCamera.backgroundColor;
            background.a = 0f;
            targetCamera.backgroundColor = background;
        }
    }
#endif
}
