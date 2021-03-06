//
// https://github.com/SteveKChiu/WebCacheMonk
//
// Copyright 2015, Steve K. Chiu <steve.k.chiu@gmail.com>
//
// The MIT License (http://www.opensource.org/licenses/mit-license.php)
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//

import Foundation

//---------------------------------------------------------------------------

public enum WebCachePolicy {
    case `default`
    case keep
    case update
    case expired(TimeInterval)
    
    public static func ExpiredInSeconds(_ seconds: Double) -> WebCachePolicy {
        return .expired(Date.timeIntervalSinceReferenceDate + seconds)
    }

    public static func ExpiredInMinutes(_ minutes: Double) -> WebCachePolicy {
        return .expired(Date.timeIntervalSinceReferenceDate + minutes * 60)
    }
    
    public static func ExpiredInHours(_ hours: Double) -> WebCachePolicy {
        return .expired(Date.timeIntervalSinceReferenceDate + hours * (60 * 60))
    }
    
    public static func ExpiredInDays(_ days: Double) -> WebCachePolicy {
        return .expired(Date.timeIntervalSinceReferenceDate + days * (24 * 60 * 60))
    }
    
    public static func ExpiredDate(_ date: Date) -> WebCachePolicy {
        return .expired(date.timeIntervalSinceReferenceDate)
    }
    
    public static func Description(_ string: String?) -> WebCachePolicy {
        if let string = string {
            if string == "keep" {
                return .keep
            } else if string == "update" {
                return .update
            } else if let time = Double(string) {
                return .expired(time)
            }
        }
        return .keep
    }
    
    public var description: String {
        switch self {
        case .update:
            return "update"
        case let .expired(time):
            return String(time)
        default:
            return "keep"
        }
    }
    
    public var isExpired: Bool {
        switch self {
        case let .expired(time):
            return time < Date.timeIntervalSinceReferenceDate
        default:
            return false
        }
    }
}

//---------------------------------------------------------------------------

public func == (lhs: WebCachePolicy, rhs: WebCachePolicy) -> Bool {
    switch (lhs, rhs) {
    case (.default, .default):
        return true
    case (.keep, .keep):
        return true
    case (.default, .keep):
        return true
    case (.keep, .default):
        return true
    case (.update, .update):
        return true
    case let (.expired(a), .expired(b)):
        return a == b
    default:
        return false
    }
}

public func != (lhs: WebCachePolicy, rhs: WebCachePolicy) -> Bool {
    return !(lhs == rhs)
}
