using System;
using System.IO;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class WorldMobileRenderingContractTests
{
    private const string ControllerTypeName =
        "Maaso.World.WorldQualityController, Assembly-CSharp";

    [Test]
    public void RuntimeFallbackProfilesEnableStableMobileShadows()
    {
        Type controllerType = Type.GetType(ControllerTypeName);
        Assert.That(controllerType, Is.Not.Null);

        int previousTargetFrameRate = Application.targetFrameRate;
        ShadowQuality previousShadows = QualitySettings.shadows;
        ShadowResolution previousResolution = QualitySettings.shadowResolution;
        ShadowProjection previousProjection = QualitySettings.shadowProjection;
        int previousCascades = QualitySettings.shadowCascades;
        float previousDistance = QualitySettings.shadowDistance;
        int previousAntialiasing = QualitySettings.antiAliasing;
        float previousLodBias = QualitySettings.lodBias;
        float previousWidthScale = ScalableBufferManager.widthScaleFactor;
        float previousHeightScale = ScalableBufferManager.heightScaleFactor;
        var root = new GameObject("RuntimeWorldQualityFixture");
        try
        {
            Component controller = root.AddComponent(controllerType);
            MethodInfo initialize = controllerType.GetMethod("InitializeForRuntime");
            Assert.That(initialize, Is.Not.Null);
            initialize.Invoke(controller, null);

            Assert.That(QualitySettings.antiAliasing, Is.GreaterThanOrEqualTo(2));
            Assert.That(QualitySettings.lodBias, Is.GreaterThanOrEqualTo(1f));

            string source = File.ReadAllText(
                "Assets/MaasoWorld/Scripts/WorldQualityController.cs");
            StringAssert.Contains("QualitySettings.shadows = ShadowQuality.All", source);
            StringAssert.Contains("ShadowProjection.StableFit", source);
            StringAssert.Contains("WorldQualityTier.High ? 4 : 2", source);
        }
        finally
        {
            UnityEngine.Object.DestroyImmediate(root);
            Application.targetFrameRate = previousTargetFrameRate;
            QualitySettings.shadows = previousShadows;
            QualitySettings.shadowResolution = previousResolution;
            QualitySettings.shadowProjection = previousProjection;
            QualitySettings.shadowCascades = previousCascades;
            QualitySettings.shadowDistance = previousDistance;
            QualitySettings.antiAliasing = previousAntialiasing;
            QualitySettings.lodBias = previousLodBias;
            ScalableBufferManager.ResizeBuffers(previousWidthScale, previousHeightScale);
        }
    }
}
