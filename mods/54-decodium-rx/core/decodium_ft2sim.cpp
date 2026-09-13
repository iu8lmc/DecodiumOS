// decodium_ft2sim: write a 3.75 s FT2 test slot (12 kHz, 16-bit mono WAV)
// with one Decodium FT2 signal in Gaussian noise. Used by the DecodiumOS
// build to prove that decodium_rx_core decodes FT2; not shipped.
//
//   decodium_ft2sim "CQ IU8LMC JN70" <f0 Hz> <snr dB> <out.wav>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

#include <QFile>
#include <QString>

#include "Modulator/FtxMessageEncoder.hpp"
#include "Modulator/FtxWaveformGenerator.hpp"

int main (int argc, char* argv[])
{
  if (argc != 5)
    {
      std::fprintf (stderr, "usage: %s MESSAGE F0 SNR OUT.wav\n", argv[0]);
      return 2;
    }
  QString const message = QString::fromLocal8Bit (argv[1]);
  float const f0 = static_cast<float> (std::atof (argv[2]));
  double const snr = std::atof (argv[3]);

  auto const encoded = decodium::txmsg::encodeFt2 (message);
  if (!encoded.ok || encoded.tones.size () < 103)
    {
      std::fprintf (stderr, "cannot encode FT2 message\n");
      return 1;
    }
  constexpr int kRate = 12000;
  constexpr int kSlot = 45000;        // 3.75 s
  constexpr int kNsps = 288;          // FT2 samples per symbol at 12 kHz
  constexpr int kStart = kRate / 2;   // signal starts 0.5 s into the slot
  auto const wave = decodium::txwave::generateFt2Wave (encoded.tones.constData (), 103,
                                                       kNsps, float (kRate), f0);

  // SNR in the 2500 Hz reference bandwidth: unit-amplitude tone (power 0.5)
  // against white noise spread over the 6 kHz Nyquist band.
  double const sigma = std::sqrt (0.5 * (kRate / 2.0) / 2500.0 / std::pow (10.0, snr / 10.0));
  std::mt19937 rng {12345};
  std::normal_distribution<double> gauss {0.0, sigma};
  std::vector<double> mix (kSlot);
  for (int i = 0; i < kSlot; ++i)
    {
      mix[i] = gauss (rng);
      int const k = i - kStart;
      if (k >= 0 && k < wave.size ())
        mix[i] += wave[k];
    }
  double rms = 0.0;
  for (double v : mix) rms += v * v;
  rms = std::sqrt (rms / kSlot);
  double const scale = 32767.0 / (8.0 * rms);

  QByteArray data;
  data.reserve (kSlot * 2);
  for (double v : mix)
    {
      long s = std::lround (v * scale);
      s = std::max (-32768L, std::min (32767L, s));
      data.append (char (s & 0xff));
      data.append (char ((s >> 8) & 0xff));
    }
  auto le32 = [] (quint32 v) { QByteArray b (4, 0); for (int i = 0; i < 4; ++i) b[i] = char (v >> (8 * i)); return b; };
  auto le16 = [] (quint16 v) { QByteArray b (2, 0); b[0] = char (v); b[1] = char (v >> 8); return b; };
  QByteArray wav = "RIFF" + le32 (36 + data.size ()) + "WAVEfmt " + le32 (16) + le16 (1) + le16 (1)
                   + le32 (kRate) + le32 (kRate * 2) + le16 (2) + le16 (16) + "data" + le32 (data.size ()) + data;
  QFile out {QString::fromLocal8Bit (argv[4])};
  if (!out.open (QIODevice::WriteOnly) || out.write (wav) != wav.size ())
    {
      std::fprintf (stderr, "cannot write %s\n", argv[4]);
      return 1;
    }
  return 0;
}
