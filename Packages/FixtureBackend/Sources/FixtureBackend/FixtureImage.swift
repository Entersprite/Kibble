import Foundation

/// The one picture the fixture backend serves for every attachment: a
/// 320x200 PNG, a soft gradient with a lighter band, so a bubble's aspect and
/// corners are visible against it.
///
/// A literal rather than a resource or something drawn at run time: the
/// fixture package reads no clock and touches no bundle, and the same bytes on
/// every run is what `DeterminismTests` asks of everything else here.
/// Generated once with Python's `zlib` and `struct` (session 38); regenerate
/// rather than edit.
enum FixtureImage {
    static let png = Data(base64Encoded: base64)!

    private static let base64 = [
        "iVBORw0KGgoAAAANSUhEUgAAAUAAAADICAIAAAAWZq/8AAANqklEQVR42u3dB3cc1RmH8fk4pEAaCYEUSCMhNKtZkiWrxjXG",
        "xkVukotc5N6NICGmGEyRbZB7L5DmNJwCKZBig0khjTTSSAh3M5OZO3tXe6+s1bx38pzz/wrP2Tln7++8wRX9A1fcZdr2gbds",
        "323YNrW3btujbWu8t23dG2+LtrdveSLc5vSu3PzklZvMu2rjoGEb1N6xYV9668O9c/1+bevCvWvdgXhrtb177cFwa9J7z5pD",
        "aqsNu3rVYfP6Dr+370h6K8O9b+VRbSviXbPiWLzl2t6//LjaMsOuXXbi2l7Drus9ed1S05ac/MCSU4YtVvvg4tPaFsX70KIz",
        "8Xq0fbjnbLju9K7vfur6hebdsOBpw+arfWT+F9ObF+6j876kbW64j839crwubR/v+kq4Oel9Ys5X1WYbduOsc+bNPPfJmV9L",
        "785wn7rz69pmxLtpxjfiTdf26enfVLvDsJvv+NbN0wwLqNeq3tV+1ruUeu3qne1lvbd89plgVOvdXPF60+nmvV6Vrpx6uyte",
        "bzrdvNer0i1dryngPNW7zs96l1OvXb1z/ax3+ojVWxSwsd5tguo1pJvresN0K1rvYkH1GtLNdb1husOtVw9YRr1XbRr0st6+",
        "YdZb/rM5X/XesPBpL+udOcx6y382X0a9iYCF1LuReu3q7fWz3gXUa1fvNKt6o4BHsV6Vrpx611S83nS6ea9XpSun3jkVrzed",
        "7ujWWwj48uvdQr129a7ws94e6rWrd8Zo16sCHtl6y/zZOyL1rhdUryHdXNdb5s/eEal3nqB6DelKqveWqcUBl6t3+E81/Kz3",
        "6tWHvax3yTDrHf5TDT/rvXH2OS/rnap269TzwSjVu8nPeldRbwUeWsmpd5bf9eoBG9PNe70j9si5b7SfSQ6v3nS6ea93xB45",
        "zxztZ5I29SYCFvLIeUTqXUu9Uh85j0i9XdR7Xg84v/XmEhgNUa9oolCBenMJjIaoN5luFDA8EB4ID5QDjKY9Y19vGDA8EB4I",
        "DxTCA53qvXXK+QAeCA+EB8rhgU71FgUMD4QHwgMz5YFO9d425dsBPBAeCA+UwwPL1zslrjcRMDwQHggPFMADneqNAoYHwgPh",
        "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",
        "MLKv9839B8FK9ldrwO/xAAAAAElFTkSuQmCC"
    ].joined()
}
