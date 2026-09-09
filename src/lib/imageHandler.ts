import { Filesystem, Directory } from '@capacitor/filesystem';

export async function generateThumbnail(imageFile: File, maxWidth = 200, maxHeight = 200): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.readAsDataURL(imageFile);
    reader.onload = (event) => {
      const img = new Image();
      img.src = event.target?.result as string;
      img.onload = () => {
        const canvas = document.createElement('canvas');
        let width = img.width;
        let height = img.height;

        if (width > height) {
          if (width > maxWidth) {
            height *= maxWidth / width;
            width = maxWidth;
          }
        } else {
          if (height > maxHeight) {
            width *= maxHeight / height;
            height = maxHeight;
          }
        }

        canvas.width = width;
        canvas.height = height;
        const ctx = canvas.getContext('2d');
        ctx?.drawImage(img, 0, 0, width, height);
        resolve(canvas.toDataURL('image/jpeg', 0.7));
      };
      img.onerror = reject;
    };
    reader.onerror = reject;
  });
}

export async function cacheFullImage(imageFile: File, filename: string): Promise<string> {
    const reader = new FileReader();
    return new Promise((resolve, reject) => {
        reader.onload = async () => {
            try {
                const base64 = reader.result as string;
                // Remove data URL prefix
                const base64Data = base64.split(',')[1];
                await Filesystem.writeFile({
                    path: `cache/${filename}`,
                    data: base64Data,
                    directory: Directory.Data,
                });
                const uri = await Filesystem.getUri({
                    path: `cache/${filename}`,
                    directory: Directory.Data,
                });
                resolve(uri.uri);
            } catch (err) {
                reject(err);
            }
        };
        reader.readAsDataURL(imageFile);
    });
}
