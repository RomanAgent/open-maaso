using System;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class MaasoVrmLoaderTests
{
    private const string LoaderTypeName =
        "Maaso.Avatar.MaasoVrmLoader, Maaso.VrmBridge";

    [Test]
    public void AwaitCallerUsesNoThreadRuntimeOnWebGL()
    {
        Type loaderType = Type.GetType(LoaderTypeName);
        Assert.That(loaderType, Is.Not.Null, LoaderTypeName);
        MethodInfo factory = loaderType.GetMethod(
            "CreateAwaitCaller",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(factory, Is.Not.Null);

        object webGLCaller = factory.Invoke(
            null,
            new object[] { RuntimePlatform.WebGLPlayer, true });
        object desktopCaller = factory.Invoke(
            null,
            new object[] { RuntimePlatform.WindowsPlayer, true });
        object editModeCaller = factory.Invoke(
            null,
            new object[] { RuntimePlatform.WebGLPlayer, false });

        Assert.That(
            webGLCaller.GetType().FullName,
            Is.EqualTo("UniGLTF.RuntimeOnlyNoThreadAwaitCaller"));
        Assert.That(
            desktopCaller.GetType().FullName,
            Is.EqualTo("UniGLTF.RuntimeOnlyAwaitCaller"));
        Assert.That(
            editModeCaller.GetType().FullName,
            Is.EqualTo("UniGLTF.ImmediateCaller"));
    }
}
