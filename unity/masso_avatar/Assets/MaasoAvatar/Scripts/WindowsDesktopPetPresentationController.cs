using System;
using System.Collections.Generic;
using UnityEngine;

#if UNITY_STANDALONE_WIN && !UNITY_EDITOR
using UnityEngine.Rendering;
#endif

namespace Maaso.Avatar
{
    [DefaultExecutionOrder(10000)]
    [DisallowMultipleComponent]
    internal sealed class WindowsDesktopPetPresentationController : MonoBehaviour
    {
#if UNITY_STANDALONE_WIN && !UNITY_EDITOR
        private const string DesktopPetArgument = "-maasoDesktopPet";
        private const string DesktopPetQualityArgument =
            "-maasoDesktopPetQuality";
        private const string DesktopPetFpsArgument = "-maasoDesktopPetFps";
        private const int DesktopPetLayer = 31;
        private const double CaptureResourceRetrySeconds = 0.75;
        private static readonly Color TransparentBackground = Color.clear;
        private static readonly float[] CrispCaptureSsaaScales =
            { 4f, 3f, 2f, 1f };
        private static readonly int[] CrispCaptureMsaaSamples = { 4, 2, 1 };
        private static readonly float[] BalancedCaptureSsaaScales = { 2f, 1f };
        private static readonly int[] BalancedCaptureMsaaSamples = { 2, 1 };
        private static readonly float[] EcoCaptureSsaaScales = { 1f };
        private static readonly int[] EcoCaptureMsaaSamples = { 1 };

        private readonly Dictionary<Transform, int> originalLayers =
            new Dictionary<Transform, int>();
        private readonly Dictionary<Camera, bool> otherCameraStates =
            new Dictionary<Camera, bool>();
        private readonly Dictionary<Canvas, bool> canvasStates =
            new Dictionary<Canvas, bool>();
        private UnityAvatarCommandReceiver receiver;
        private UnityWorldLightingController companionLighting;
        private Transform avatarRoot;
        private Camera targetCamera;
        private CameraClearFlags originalClearFlags;
        private Color originalBackgroundColor;
        private int originalCullingMask;
        private bool originalAllowHdr;
        private bool originalAllowMsaa;
        private Vector3 originalCameraPosition;
        private Quaternion originalCameraRotation;
        private float originalFieldOfView;
        private float originalNearClipPlane;
        private float originalFarClipPlane;
        private bool cameraConfigured;
        private int nextSurfaceRefreshFrame;
        private int nextAvatarLayerRefreshFrame;
        private int nextAvatarDiscoveryFrame;
        private Renderer[] avatarRenderers = Array.Empty<Renderer>();
        private WindowsDesktopPetFramePublisher framePublisher;
        private Camera captureCamera;
        private RenderTexture captureMsaaTexture;
        private RenderTexture captureResolvedTexture;
        private RenderTexture captureOutputTexture;
        private CommandBuffer readbackCommandBuffer;
        private double nextCaptureTime;
        private int captureOutputWidth;
        private int captureOutputHeight;
        private int captureInternalWidth;
        private int captureInternalHeight;
        private int captureEpoch;
        private int readbackEpoch = -1;
        private bool readbackInFlight;
        private bool captureFailureReported;
        private bool shuttingDown;
        private double captureIntervalSeconds = 1.0 / 30.0;
        private float[] captureSsaaScales = CrispCaptureSsaaScales;
        private int[] captureMsaaSamples = CrispCaptureMsaaSamples;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
            string[] arguments = Environment.GetCommandLineArgs();
            foreach (string argument in arguments)
            {
                if (!string.Equals(
                    argument,
                    DesktopPetArgument,
                    StringComparison.Ordinal))
                {
                    continue;
                }

                if (FindAnyObjectByType<WindowsDesktopPetPresentationController>() != null)
                {
                    return;
                }
                var host = new GameObject("Maaso Windows Desktop Pet Presentation");
                host.AddComponent<WindowsDesktopPetPresentationController>();
                DontDestroyOnLoad(host);
                Application.runInBackground = true;
                return;
            }
        }

        private void Awake()
        {
            Application.runInBackground = true;
            ReadPresentationArguments(Environment.GetCommandLineArgs());
            WindowsDesktopPetFramePublisher.TryCreateFromCommandLine(
                out framePublisher);
        }

        private void Start()
        {
            EnableCompanionLighting();
        }

        private void EnableCompanionLighting()
        {
            companionLighting ??=
                FindAnyObjectByType<UnityWorldLightingController>();
            companionLighting?.EnterCompanionLighting();
        }

        private void DisableCompanionLighting()
        {
            companionLighting?.ExitCompanionLighting();
            companionLighting = null;
        }

        private void ReadPresentationArguments(string[] arguments)
        {
            string quality = "crisp";
            int targetFps = 30;
            for (int index = 0; index + 1 < arguments.Length; index++)
            {
                if (string.Equals(
                    arguments[index],
                    DesktopPetQualityArgument,
                    StringComparison.Ordinal))
                {
                    string candidate = arguments[index + 1];
                    if (string.Equals(candidate, "eco", StringComparison.Ordinal) ||
                        string.Equals(candidate, "balanced", StringComparison.Ordinal) ||
                        string.Equals(candidate, "crisp", StringComparison.Ordinal))
                    {
                        quality = candidate;
                    }
                }
                else if (string.Equals(
                    arguments[index],
                    DesktopPetFpsArgument,
                    StringComparison.Ordinal) &&
                    int.TryParse(arguments[index + 1], out int candidateFps) &&
                    (candidateFps == 24 || candidateFps == 30 || candidateFps == 60))
                {
                    targetFps = candidateFps;
                }
            }

            ApplyPresentationConfig(quality, targetFps);
        }

        internal void ApplyPresentationConfig(string quality, int targetFps)
        {
            if ((targetFps != 24 && targetFps != 30 && targetFps != 60) ||
                (!string.Equals(quality, "eco", StringComparison.Ordinal) &&
                 !string.Equals(quality, "balanced", StringComparison.Ordinal) &&
                 !string.Equals(quality, "crisp", StringComparison.Ordinal)))
            {
                return;
            }

            float[] nextSsaaScales;
            int[] nextMsaaSamples;
            switch (quality)
            {
                case "eco":
                    nextSsaaScales = EcoCaptureSsaaScales;
                    nextMsaaSamples = EcoCaptureMsaaSamples;
                    break;
                case "balanced":
                    nextSsaaScales = BalancedCaptureSsaaScales;
                    nextMsaaSamples = BalancedCaptureMsaaSamples;
                    break;
                default:
                    nextSsaaScales = CrispCaptureSsaaScales;
                    nextMsaaSamples = CrispCaptureMsaaSamples;
                    break;
            }
            double nextInterval = 1.0 / targetFps;
            if (ReferenceEquals(captureSsaaScales, nextSsaaScales) &&
                ReferenceEquals(captureMsaaSamples, nextMsaaSamples) &&
                Math.Abs(captureIntervalSeconds - nextInterval) < 0.000001)
            {
                return;
            }
            captureSsaaScales = nextSsaaScales;
            captureMsaaSamples = nextMsaaSamples;
            captureIntervalSeconds = nextInterval;
            ReleaseCaptureTextures();
            nextCaptureTime = 0;
        }

        private void LateUpdate()
        {
            if (Time.frameCount >= nextAvatarDiscoveryFrame)
            {
                receiver = receiver != null
                    ? receiver
                    : FindAnyObjectByType<UnityAvatarCommandReceiver>();
                Transform nextRoot = receiver != null
                    ? receiver.ActiveAvatarRoot
                    : null;
                nextAvatarDiscoveryFrame = Time.frameCount +
                    (nextRoot == null ? 15 : 60);

                if (nextRoot != avatarRoot)
                {
                    RestoreAvatarLayers();
                    avatarRoot = nextRoot;
                    nextAvatarLayerRefreshFrame = 0;
                }
                avatarRenderers = avatarRoot != null
                    ? avatarRoot.GetComponentsInChildren<Renderer>(true)
                    : Array.Empty<Renderer>();
            }
            if (avatarRoot == null)
            {
                return;
            }
            if (Time.frameCount >= nextAvatarLayerRefreshFrame)
            {
                nextAvatarLayerRefreshFrame = Time.frameCount + 60;
                ApplyAvatarLayer(avatarRoot);
            }

            Camera nextCamera = Camera.main;
            if (nextCamera != targetCamera)
            {
                RestoreCamera();
                targetCamera = nextCamera;
                CaptureAndConfigureCamera();
                nextSurfaceRefreshFrame = 0;
            }
            if (targetCamera == null)
            {
                return;
            }

            ConfigurePresentationSurfaces();
            UpdateCameraFraming();
            TryCaptureFrame();
        }

        private void OnDestroy()
        {
            DisableCompanionLighting();
            shuttingDown = true;
            ReleaseCaptureResources();
            framePublisher?.Dispose();
            framePublisher = null;
            RestoreAvatarLayers();
            RestoreCamera();
            foreach (KeyValuePair<Camera, bool> entry in otherCameraStates)
            {
                if (entry.Key != null)
                {
                    entry.Key.enabled = entry.Value;
                }
            }
            foreach (KeyValuePair<Canvas, bool> entry in canvasStates)
            {
                if (entry.Key != null)
                {
                    entry.Key.enabled = entry.Value;
                }
            }
            otherCameraStates.Clear();
            canvasStates.Clear();
        }

        private void ApplyAvatarLayer(Transform root)
        {
            foreach (Transform child in root.GetComponentsInChildren<Transform>(true))
            {
                if (child == null)
                {
                    continue;
                }
                if (!originalLayers.ContainsKey(child))
                {
                    originalLayers[child] = child.gameObject.layer;
                }
                child.gameObject.layer = DesktopPetLayer;
            }
        }

        private void RestoreAvatarLayers()
        {
            foreach (KeyValuePair<Transform, int> entry in originalLayers)
            {
                if (entry.Key != null)
                {
                    entry.Key.gameObject.layer = entry.Value;
                }
            }
            originalLayers.Clear();
            avatarRoot = null;
        }

        private void CaptureAndConfigureCamera()
        {
            if (targetCamera == null)
            {
                return;
            }
            originalClearFlags = targetCamera.clearFlags;
            originalBackgroundColor = targetCamera.backgroundColor;
            originalCullingMask = targetCamera.cullingMask;
            originalAllowHdr = targetCamera.allowHDR;
            originalAllowMsaa = targetCamera.allowMSAA;
            originalCameraPosition = targetCamera.transform.position;
            originalCameraRotation = targetCamera.transform.rotation;
            originalFieldOfView = targetCamera.fieldOfView;
            originalNearClipPlane = targetCamera.nearClipPlane;
            originalFarClipPlane = targetCamera.farClipPlane;
            cameraConfigured = true;
            ConfigureTargetCamera();
        }

        private void ConfigureTargetCamera()
        {
            targetCamera.clearFlags = CameraClearFlags.SolidColor;
            targetCamera.backgroundColor = TransparentBackground;
            targetCamera.cullingMask = 1 << DesktopPetLayer;
            targetCamera.allowHDR = false;
            targetCamera.allowMSAA = true;
        }

        private void RestoreCamera()
        {
            if (!cameraConfigured || targetCamera == null)
            {
                targetCamera = null;
                cameraConfigured = false;
                return;
            }
            targetCamera.clearFlags = originalClearFlags;
            targetCamera.backgroundColor = originalBackgroundColor;
            targetCamera.cullingMask = originalCullingMask;
            targetCamera.allowHDR = originalAllowHdr;
            targetCamera.allowMSAA = originalAllowMsaa;
            targetCamera.transform.SetPositionAndRotation(
                originalCameraPosition,
                originalCameraRotation);
            targetCamera.fieldOfView = originalFieldOfView;
            targetCamera.nearClipPlane = originalNearClipPlane;
            targetCamera.farClipPlane = originalFarClipPlane;
            targetCamera = null;
            cameraConfigured = false;
        }

        private void ConfigurePresentationSurfaces()
        {
            ConfigureTargetCamera();
            if (Time.frameCount < nextSurfaceRefreshFrame)
            {
                return;
            }
            nextSurfaceRefreshFrame = Time.frameCount + 60;
            foreach (Camera camera in Camera.allCameras)
            {
                if (camera == null || camera == targetCamera)
                {
                    continue;
                }
                if (!otherCameraStates.ContainsKey(camera))
                {
                    otherCameraStates[camera] = camera.enabled;
                }
                camera.enabled = false;
            }
            foreach (Canvas canvas in FindObjectsByType<Canvas>(
                         FindObjectsInactive.Exclude,
                         FindObjectsSortMode.None))
            {
                if (canvas == null)
                {
                    continue;
                }
                if (!canvasStates.ContainsKey(canvas))
                {
                    canvasStates[canvas] = canvas.enabled;
                }
                canvas.enabled = false;
            }
        }

        private void UpdateCameraFraming()
        {
            Bounds bounds = default;
            bool hasBounds = false;
            foreach (Renderer renderer in avatarRenderers)
            {
                if (renderer == null || !renderer.enabled)
                {
                    continue;
                }
                if (!hasBounds)
                {
                    bounds = renderer.bounds;
                    hasBounds = true;
                }
                else
                {
                    bounds.Encapsulate(renderer.bounds);
                }
            }
            if (!hasBounds)
            {
                return;
            }

            Vector3 forward = targetCamera.transform.forward.normalized;
            Vector3 up = targetCamera.transform.up.normalized;
            Vector3 right = targetCamera.transform.right.normalized;
            targetCamera.fieldOfView = 28f;
            float verticalExtent = Mathf.Max(
                ProjectedExtent(bounds.extents, up),
                0.25f);
            float horizontalExtent = Mathf.Max(
                ProjectedExtent(bounds.extents, right),
                0.12f);
            float verticalHalfAngle =
                targetCamera.fieldOfView * 0.5f * Mathf.Deg2Rad;
            float horizontalHalfAngle = Mathf.Atan(
                Mathf.Tan(verticalHalfAngle) * Mathf.Max(targetCamera.aspect, 0.1f));
            float distance = Mathf.Max(
                verticalExtent / Mathf.Tan(verticalHalfAngle),
                horizontalExtent / Mathf.Tan(horizontalHalfAngle));
            distance *= 1.12f;
            Vector3 center = bounds.center + up * (bounds.extents.y * 0.04f);
            targetCamera.transform.SetPositionAndRotation(
                center - forward * distance,
                Quaternion.LookRotation(forward, up));
            targetCamera.nearClipPlane = Mathf.Max(
                0.01f,
                distance - bounds.extents.magnitude * 1.5f);
            targetCamera.farClipPlane =
                distance + bounds.extents.magnitude * 2.5f;
        }

        private static float ProjectedExtent(Vector3 extents, Vector3 axis)
        {
            return Mathf.Abs(axis.x) * extents.x +
                Mathf.Abs(axis.y) * extents.y +
                Mathf.Abs(axis.z) * extents.z;
        }

        private void TryCaptureFrame()
        {
            if (shuttingDown ||
                framePublisher == null ||
                targetCamera == null ||
                readbackInFlight)
            {
                return;
            }

            double now = Time.realtimeSinceStartupAsDouble;
            if (now < nextCaptureTime)
            {
                return;
            }

            try
            {
                if (!EnsureCaptureResources())
                {
                    nextCaptureTime = now + CaptureResourceRetrySeconds;
                    return;
                }
            }
            catch (Exception exception)
            {
                nextCaptureTime = now + CaptureResourceRetrySeconds;
                ReportCaptureFailure(exception.Message);
                return;
            }
            nextCaptureTime = now + captureIntervalSeconds;

            try
            {
                ConfigureCaptureCamera();
                captureCamera.Render();

                readbackCommandBuffer ??= new CommandBuffer
                {
                    name = "Maaso Windows Desktop Pet BGRA Readback",
                };
                readbackCommandBuffer.Clear();
                if (captureMsaaTexture.antiAliasing > 1)
                {
                    readbackCommandBuffer.ResolveAntiAliasedSurface(
                        captureMsaaTexture,
                        captureResolvedTexture);
                }
                else
                {
                    readbackCommandBuffer.Blit(
                        captureMsaaTexture,
                        captureResolvedTexture);
                }
                readbackCommandBuffer.Blit(
                    captureResolvedTexture,
                    captureOutputTexture);

                int frameWidth = captureOutputWidth;
                int frameHeight = captureOutputHeight;
                int frameEpoch = captureEpoch;
                readbackInFlight = true;
                readbackEpoch = frameEpoch;
                readbackCommandBuffer.RequestAsyncReadback(
                    captureOutputTexture,
                    0,
                    TextureFormat.BGRA32,
                    request => HandleFrameReadback(
                        request,
                        frameWidth,
                        frameHeight,
                        frameEpoch));
                Graphics.ExecuteCommandBuffer(readbackCommandBuffer);
            }
            catch (Exception exception)
            {
                readbackInFlight = false;
                readbackEpoch = -1;
                ReportCaptureFailure(exception.Message);
            }
        }

        private bool EnsureCaptureResources()
        {
            int outputWidth = Screen.width;
            int outputHeight = Screen.height;
            if (outputWidth <= 0 ||
                outputHeight <= 0 ||
                outputWidth > WindowsDesktopPetFramePublisher.MaximumDimension ||
                outputHeight > WindowsDesktopPetFramePublisher.MaximumDimension)
            {
                ReportCaptureFailure(
                    "the desktop-pet output size is outside the 1..2048 protocol bounds");
                return false;
            }

            if (captureMsaaTexture != null &&
                captureResolvedTexture != null &&
                captureOutputTexture != null &&
                outputWidth == captureOutputWidth &&
                outputHeight == captureOutputHeight)
            {
                return true;
            }

            ReleaseCaptureTextures();

            var attemptedInternalSizes = new HashSet<long>();
            foreach (float requestedScale in captureSsaaScales)
            {
                float ssaaScale = Mathf.Min(
                    requestedScale,
                    Mathf.Min(
                        (float)WindowsDesktopPetFramePublisher.MaximumDimension /
                            outputWidth,
                        (float)WindowsDesktopPetFramePublisher.MaximumDimension /
                            outputHeight));
                int internalWidth = Mathf.Clamp(
                    Mathf.RoundToInt(outputWidth * ssaaScale),
                    outputWidth,
                    WindowsDesktopPetFramePublisher.MaximumDimension);
                int internalHeight = Mathf.Clamp(
                    Mathf.RoundToInt(outputHeight * ssaaScale),
                    outputHeight,
                    WindowsDesktopPetFramePublisher.MaximumDimension);
                long internalSizeKey = ((long)internalWidth << 32) |
                    (uint)internalHeight;
                if (!attemptedInternalSizes.Add(internalSizeKey))
                {
                    continue;
                }

                foreach (int requestedSamples in captureMsaaSamples)
                {
                    var msaaDescriptor = new RenderTextureDescriptor(
                        internalWidth,
                        internalHeight,
                        RenderTextureFormat.ARGB32,
                        24)
                    {
                        useMipMap = false,
                        autoGenerateMips = false,
                        sRGB = QualitySettings.activeColorSpace == ColorSpace.Linear,
                        msaaSamples = requestedSamples,
                        bindMS = requestedSamples > 1,
                    };
                    int supportedSamples =
                        SystemInfo.GetRenderTextureSupportedMSAASampleCount(
                            msaaDescriptor);
                    if (supportedSamples < requestedSamples)
                    {
                        continue;
                    }

                    var resolvedDescriptor = msaaDescriptor;
                    resolvedDescriptor.depthBufferBits = 0;
                    resolvedDescriptor.msaaSamples = 1;
                    resolvedDescriptor.bindMS = false;
                    var outputDescriptor = resolvedDescriptor;
                    outputDescriptor.width = outputWidth;
                    outputDescriptor.height = outputHeight;

                    RenderTexture nextMsaaTexture = CreateRenderTexture(
                        msaaDescriptor,
                        $"Maaso Desktop Pet {ssaaScale:0.##}x SSAA + " +
                        $"{requestedSamples}x MSAA");
                    RenderTexture nextResolvedTexture = CreateRenderTexture(
                        resolvedDescriptor,
                        "Maaso Desktop Pet Resolved");
                    RenderTexture nextOutputTexture = CreateRenderTexture(
                        outputDescriptor,
                        "Maaso Desktop Pet BGRA Output");
                    if (nextMsaaTexture != null &&
                        nextResolvedTexture != null &&
                        nextOutputTexture != null)
                    {
                        captureMsaaTexture = nextMsaaTexture;
                        captureResolvedTexture = nextResolvedTexture;
                        captureOutputTexture = nextOutputTexture;
                        captureOutputWidth = outputWidth;
                        captureOutputHeight = outputHeight;
                        captureInternalWidth = internalWidth;
                        captureInternalHeight = internalHeight;
                        return true;
                    }

                    ReleaseRenderTexture(ref nextMsaaTexture);
                    ReleaseRenderTexture(ref nextResolvedTexture);
                    ReleaseRenderTexture(ref nextOutputTexture);
                }
            }

            ReportCaptureFailure("Unity could not allocate the capture textures");
            return false;
        }

        private void ConfigureCaptureCamera()
        {
            if (captureCamera == null)
            {
                var captureHost = new GameObject("Maaso Desktop Pet Capture Camera")
                {
                    hideFlags = HideFlags.HideAndDontSave,
                };
                captureHost.transform.SetParent(transform, false);
                captureCamera = captureHost.AddComponent<Camera>();
            }

            captureCamera.CopyFrom(targetCamera);
            captureCamera.transform.SetPositionAndRotation(
                targetCamera.transform.position,
                targetCamera.transform.rotation);
            captureCamera.enabled = false;
            captureCamera.clearFlags = CameraClearFlags.SolidColor;
            captureCamera.backgroundColor = TransparentBackground;
            captureCamera.cullingMask = 1 << DesktopPetLayer;
            captureCamera.allowHDR = false;
            captureCamera.allowMSAA = true;
            captureCamera.targetTexture = captureMsaaTexture;
        }

        private void HandleFrameReadback(
            AsyncGPUReadbackRequest request,
            int frameWidth,
            int frameHeight,
            int frameEpoch)
        {
            if (readbackEpoch == frameEpoch)
            {
                readbackInFlight = false;
                readbackEpoch = -1;
            }
            if (shuttingDown ||
                framePublisher == null ||
                frameEpoch != captureEpoch)
            {
                return;
            }
            if (request.hasError)
            {
                ReportCaptureFailure("the asynchronous GPU readback failed");
                return;
            }

            bool published = framePublisher.Publish(
                request.GetData<byte>(),
                frameWidth,
                frameHeight,
                frameWidth * WindowsDesktopPetFramePublisher.BytesPerPixel,
                topDown: true);
            if (!published)
            {
                ReportCaptureFailure("the shared-frame publisher rejected the BGRA frame");
                return;
            }
            captureFailureReported = false;
        }

        private static RenderTexture CreateRenderTexture(
            RenderTextureDescriptor descriptor,
            string textureName)
        {
            var texture = new RenderTexture(descriptor)
            {
                name = textureName,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp,
            };
            if (texture.Create())
            {
                return texture;
            }
            Destroy(texture);
            return null;
        }

        private void ReleaseCaptureResources()
        {
            ReleaseCaptureTextures();
            if (captureCamera != null)
            {
                Destroy(captureCamera.gameObject);
                captureCamera = null;
            }
            readbackCommandBuffer?.Release();
            readbackCommandBuffer = null;
            readbackInFlight = false;
            readbackEpoch = -1;
        }

        private void ReleaseCaptureTextures()
        {
            captureEpoch = unchecked(captureEpoch + 1);
            ReleaseRenderTexture(ref captureMsaaTexture);
            ReleaseRenderTexture(ref captureResolvedTexture);
            ReleaseRenderTexture(ref captureOutputTexture);
            captureOutputWidth = 0;
            captureOutputHeight = 0;
            captureInternalWidth = 0;
            captureInternalHeight = 0;
        }

        private static void ReleaseRenderTexture(ref RenderTexture texture)
        {
            if (texture == null)
            {
                return;
            }
            if (texture.IsCreated())
            {
                texture.Release();
            }
            Destroy(texture);
            texture = null;
        }

        private void ReportCaptureFailure(string reason)
        {
            if (captureFailureReported)
            {
                return;
            }
            captureFailureReported = true;
            Debug.LogWarning("Maaso Windows desktop-pet capture paused: " + reason);
        }
#endif
    }
}
