import Foundation
import Photos
import ImageIO
import CoreLocation

public enum PhotosImporter {
    /// Adds both resources in ONE change request so Photos receives a Live Photo.
    /// Requests add-only permission and never moves/deletes the exported files.
    public static func importPair(_ result: ConversionResult) async throws {
        try Task.checkCancellation()
        guard result.supportsPhotosImport, let videoURL = result.videoURL else {
            throw ConversionError.unsupportedPhotosImport
        }
        try await LivePhotoValidator.validate(photoURL: result.photoURL, videoURL: videoURL)
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw ConversionError.photosPermissionDenied
        }
        try Task.checkCancellation()
        let location = location(from: result.photoURL)
        // Once this transaction has been submitted it cannot safely be cancelled.
        // Always report its actual outcome, even if the surrounding batch stops.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.originalFilename = result.photoURL.lastPathComponent
                photoOptions.shouldMoveFile = false
                let movieOptions = PHAssetResourceCreationOptions()
                movieOptions.originalFilename = videoURL.lastPathComponent
                movieOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: result.photoURL, options: photoOptions)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: movieOptions)
                if let date = result.creationDate { request.creationDate = date }
                if let location { request.location = location }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ConversionError.photosImportFailed(
                        error?.localizedDescription ?? "Photos did not complete the change request."))
                }
            }
        }
    }

    private static func location(from imageURL: URL) -> CLLocation? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let latitudeNumber = gps[kCGImagePropertyGPSLatitude as String] as? NSNumber,
              let longitudeNumber = gps[kCGImagePropertyGPSLongitude as String] as? NSNumber,
              let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
              let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String else { return nil }
        let latitude = latitudeNumber.doubleValue * (latitudeRef.uppercased() == "S" ? -1 : 1)
        let longitude = longitudeNumber.doubleValue * (longitudeRef.uppercased() == "W" ? -1 : 1)
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard latitude.isFinite, longitude.isFinite, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}
