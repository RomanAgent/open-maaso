using System;

#if UNITY_STANDALONE_WIN && !UNITY_EDITOR
using System.IO.MemoryMappedFiles;
using System.Threading;
using Unity.Collections;
using UnityEngine;
#endif

namespace Maaso.Avatar
{
#if UNITY_STANDALONE_WIN && !UNITY_EDITOR
    internal sealed class WindowsDesktopPetFramePublisher : IDisposable
    {
        internal const uint FrameMagic = 0x4653414D; // Little-endian bytes: "MASF".
        internal const uint ProtocolVersion = 1;
        internal const int HeaderBytes = 64;
        internal const int MaximumDimension = 2048;
        internal const int BytesPerPixel = 4;
        internal const long MappingCapacity =
            HeaderBytes +
            (long)MaximumDimension * MaximumDimension * BytesPerPixel;

        private const string SessionArgument = "-maasoAvatarSession";
        private const string MappingPrefix = @"Local\MaasoAvatarFrame_";
        private const int MagicOffset = 0;
        private const int VersionOffset = 4;
        private const int SequenceBeginOffset = 8;
        private const int SequenceEndOffset = 12;
        private const int WidthOffset = 16;
        private const int HeightOffset = 20;
        private const int StrideOffset = 24;
        private const int PayloadBytesOffset = 28;
        private const int FlagsOffset = 32;
        private const int PixelsOffset = HeaderBytes;
        private const uint TopDownFlag = 1u << 0;

        private readonly MemoryMappedFile mapping;
        private readonly MemoryMappedViewAccessor view;
        private readonly byte[] pixelBuffer =
            new byte[MaximumDimension * MaximumDimension * BytesPerPixel];
        private uint publishedSequence;
        private bool disposed;

        private WindowsDesktopPetFramePublisher(string sessionToken)
        {
            string mappingName = MappingPrefix + sessionToken;
            mapping = MemoryMappedFile.CreateOrOpen(
                mappingName,
                MappingCapacity,
                MemoryMappedFileAccess.ReadWrite);
            try
            {
                view = mapping.CreateViewAccessor(
                    0,
                    MappingCapacity,
                    MemoryMappedFileAccess.ReadWrite);
            }
            catch
            {
                mapping.Dispose();
                throw;
            }

            view.WriteArray(0, pixelBuffer, 0, HeaderBytes);
            view.Write(MagicOffset, FrameMagic);
            view.Write(VersionOffset, ProtocolVersion);
            view.Write(SequenceBeginOffset, 0u);
            view.Write(SequenceEndOffset, 0u);
            view.Write(WidthOffset, 0);
            view.Write(HeightOffset, 0);
            view.Write(StrideOffset, 0);
            view.Write(PayloadBytesOffset, 0);
            view.Write(FlagsOffset, 0u);
        }

        internal static bool TryCreateFromCommandLine(
            out WindowsDesktopPetFramePublisher publisher)
        {
            publisher = null;
            string[] arguments = Environment.GetCommandLineArgs();
            string sessionToken = ArgumentValue(arguments, SessionArgument);
            if (!IsValidSessionToken(sessionToken))
            {
                return false;
            }

            try
            {
                publisher = new WindowsDesktopPetFramePublisher(sessionToken);
                return true;
            }
            catch (Exception exception)
            {
                Debug.LogWarning(
                    "Maaso could not create the Windows desktop-pet frame mapping: " +
                    exception.Message);
                return false;
            }
        }

        internal bool Publish(
            NativeArray<byte> bgraPixels,
            int width,
            int height,
            int stride,
            bool topDown)
        {
            if (disposed ||
                !bgraPixels.IsCreated ||
                width <= 0 || width > MaximumDimension ||
                height <= 0 || height > MaximumDimension ||
                stride != checked(width * BytesPerPixel))
            {
                return false;
            }

            int payloadBytes = checked(stride * height);
            if (payloadBytes > pixelBuffer.Length || bgraPixels.Length < payloadBytes)
            {
                return false;
            }

            NativeArray<byte>.Copy(
                bgraPixels,
                0,
                pixelBuffer,
                0,
                payloadBytes);
            EnforcePremultipliedBgra(payloadBytes);

            // A reader accepts a frame only when both sequence values are equal
            // and even. Mark both odd before mutation, then publish the same even
            // value to SequenceEnd first and SequenceBegin last.
            uint writingSequence = (publishedSequence + 1u) | 1u;
            view.Write(SequenceBeginOffset, writingSequence);
            view.Write(SequenceEndOffset, writingSequence);
            Thread.MemoryBarrier();

            view.Write(WidthOffset, width);
            view.Write(HeightOffset, height);
            view.Write(StrideOffset, stride);
            view.Write(PayloadBytesOffset, payloadBytes);
            view.Write(FlagsOffset, topDown ? TopDownFlag : 0u);
            view.WriteArray(PixelsOffset, pixelBuffer, 0, payloadBytes);
            Thread.MemoryBarrier();

            uint stableSequence = writingSequence + 1u;
            view.Write(SequenceEndOffset, stableSequence);
            Thread.MemoryBarrier();
            view.Write(SequenceBeginOffset, stableSequence);
            publishedSequence = stableSequence;
            return true;
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            view.Dispose();
            mapping.Dispose();
        }

        private void EnforcePremultipliedBgra(int payloadBytes)
        {
            for (int offset = 0; offset < payloadBytes; offset += BytesPerPixel)
            {
                byte alpha = pixelBuffer[offset + 3];
                if (alpha == 0)
                {
                    pixelBuffer[offset] = 0;
                    pixelBuffer[offset + 1] = 0;
                    pixelBuffer[offset + 2] = 0;
                    continue;
                }

                pixelBuffer[offset] = Math.Min(pixelBuffer[offset], alpha);
                pixelBuffer[offset + 1] = Math.Min(pixelBuffer[offset + 1], alpha);
                pixelBuffer[offset + 2] = Math.Min(pixelBuffer[offset + 2], alpha);
            }
        }

        private static string ArgumentValue(string[] arguments, string key)
        {
            for (int index = 0; index + 1 < arguments.Length; index += 1)
            {
                if (string.Equals(arguments[index], key, StringComparison.Ordinal))
                {
                    return arguments[index + 1] ?? string.Empty;
                }
            }
            return string.Empty;
        }

        private static bool IsValidSessionToken(string value)
        {
            if (value == null || value.Length != 64)
            {
                return false;
            }
            foreach (char character in value)
            {
                bool isHexadecimal =
                    (character >= '0' && character <= '9') ||
                    (character >= 'a' && character <= 'f');
                if (!isHexadecimal)
                {
                    return false;
                }
            }
            return true;
        }
    }
#endif
}
