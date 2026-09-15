export interface ReleaseAsset {
  id: number;
  name: string;
  browser_download_url: string;
  size: number;
  download_count: number;
  updated_at: string;
}

export interface GitHubRelease {
  tag_name: string;
  name: string;
  published_at: string;
  html_url: string;
  body: string;
  assets: ReleaseAsset[];
}

export interface RepoInfo {
  stargazers_count: number;
  forks_count: number;
  open_issues_count: number;
  description: string;
  html_url: string;
}
