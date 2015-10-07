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
    case Default
    case Refresh
    case Keep
    case Expired(NSTimeInterval)
    
    public static func ExpiredInSeconds(seconds: Double) -> WebCachePolicy {
        return .Expired(NSDate.timeIntervalSinceReferenceDate() + seconds)
    }

    public static func ExpiredInMinutes(minutes: Double) -> WebCachePolicy {
        return .Expired(NSDate.timeIntervalSinceReferenceDate() + minutes * 60)
    }
    
    public static func ExpiredInHours(hours: Double) -> WebCachePolicy {
        return .Expired(NSDate.timeIntervalSinceReferenceDate() + hours * (60 * 60))
    }
    
    public static func ExpiredInDays(days: Double) -> WebCachePolicy {
        return .Expired(NSDate.timeIntervalSinceReferenceDate() + days * (24 * 60 * 60))
    }
    
    public static func ExpiredDate(date: NSDate) -> WebCachePolicy {
        return .Expired(date.timeIntervalSinceReferenceDate)
    }
    
    public static func Description(string: String?) -> WebCachePolicy {
        if let string = string,
               time = Double(string) {
            return .Expired(time)
        }
        return .Keep
    }
    
    public var description: String {
        switch self {
        case let .Expired(time):
            return String(time)
        default:
            return "keep"
        }
    }
    
    public var isExpired: Bool {
        switch self {
        case let .Expired(time):
            return time < NSDate.timeIntervalSinceReferenceDate()
        default:
            return false
        }
    }
}

//---------------------------------------------------------------------------

public func == (lhs: WebCachePolicy, rhs: WebCachePolicy) -> Bool {
    switch lhs {
    case .Default, .Refresh, .Keep:
        switch rhs {
        case .Default, .Refresh, .Keep:
            return true
        default:
            return false
        }
    case let .Expired(a):
        switch rhs {
        case let .Expired(b):
            return a == b
        default:
            return false
        }
    }
}

public func != (lhs: WebCachePolicy, rhs: WebCachePolicy) -> Bool {
    return !(lhs == rhs)
}
