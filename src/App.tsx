import React, { useState, useEffect, useCallback } from 'react';
import { Navbar } from './components/Navbar';
import { Hero } from './components/Hero';
import { Features } from './components/Features';
import { Architecture } from './components/Architecture';
import { Downloads } from './components/Downloads';
import { ContactFooter } from './components/ContactFooter';
import { GitHubRelease, ReleaseAsset, RepoInfo } from './types/landing';

const GITHUB_REPO = 'lx00924-lx/flutter-app';
const GITHUB_API_BASE = 'https://api.github.com/repos';

export default function App() {
  // Theme state
  const [isDarkMode, setIsDarkMode] = useState<boolean>(() => {
    if (typeof window !== 'undefined') {
      const saved = localStorage.getItem('app_theme');
      if (saved) return saved === 'dark';
      return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    return true;
  });

  // GitHub Release data
  const [latestRelease, setLatestRelease] = useState<GitHubRelease | null>(null);
  const [repoInfo, setRepoInfo] = useState<RepoInfo | null>(null);
  const [isLoadingRelease, setIsLoadingRelease] = useState(false);

  // Apply Theme
  useEffect(() => {
    if (isDarkMode) {
      document.documentElement.classList.add('dark');
      localStorage.setItem('app_theme', 'dark');
    } else {
      document.documentElement.classList.remove('dark');
      localStorage.setItem('app_theme', 'light');
    }
  }, [isDarkMode]);

  // Fetch GitHub Releases & Repo Info
  const fetchGitHubData = useCallback(async () => {
    setIsLoadingRelease(true);
    try {
      // Fetch latest release
      const releaseRes = await fetch(`${GITHUB_API_BASE}/${GITHUB_REPO}/releases/latest`);
      if (releaseRes.ok) {
        const releaseData = await releaseRes.json();
        setLatestRelease(releaseData);
      } else {
        // Fallback to releases list if no tagged "latest"
        const listRes = await fetch(`${GITHUB_API_BASE}/${GITHUB_REPO}/releases`);
        if (listRes.ok) {
          const listData = await listRes.json();
          if (Array.isArray(listData) && listData.length > 0) {
            setLatestRelease(listData[0]);
          }
        }
      }

      // Fetch repo stars/forks
      const repoRes = await fetch(`${GITHUB_API_BASE}/${GITHUB_REPO}`);
      if (repoRes.ok) {
        const repoData = await repoRes.json();
        setRepoInfo(repoData);
      }
    } catch (err) {
      console.warn('Failed to fetch GitHub release information:', err);
    } finally {
      setIsLoadingRelease(false);
    }
  }, []);

  useEffect(() => {
    fetchGitHubData();
  }, [fetchGitHubData]);

  // Find assets for Windows (.exe / .zip) and Android (.apk)
  const androidAsset: ReleaseAsset | null =
    latestRelease?.assets.find(
      (a) => a.name.toLowerCase().endsWith('.apk') || a.name.toLowerCase().includes('android')
    ) || null;

  const windowsAsset: ReleaseAsset | null =
    latestRelease?.assets.find(
      (a) =>
        a.name.toLowerCase().endsWith('.exe') ||
        a.name.toLowerCase().includes('windows') ||
        a.name.toLowerCase().endsWith('.msix')
    ) || null;

  // Direct trigger download into browser
  const handleDownload = (downloadUrl: string, platform: string) => {
    if (!downloadUrl) return;
    // Create invisible anchor to trigger browser native download
    const link = document.createElement('a');
    link.href = downloadUrl;
    link.setAttribute('download', '');
    link.target = '_blank';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  return (
    <div className="min-h-screen bg-white dark:bg-slate-950 text-slate-900 dark:text-slate-100 selection:bg-indigo-500 selection:text-white transition-colors duration-200">
      {/* Navigation Bar */}
      <Navbar
        isDarkMode={isDarkMode}
        onToggleTheme={() => setIsDarkMode(!isDarkMode)}
        repoStars={repoInfo ? repoInfo.stargazers_count : null}
        repoForks={repoInfo ? repoInfo.forks_count : null}
      />

      <main>
        {/* Hero Section with Direct Downloads & GitHub links */}
        <Hero
          latestRelease={latestRelease}
          isLoadingRelease={isLoadingRelease}
          onDownload={handleDownload}
          androidAsset={androidAsset}
          windowsAsset={windowsAsset}
        />

        {/* Core Product Highlights */}
        <Features />

        {/* Trinity Architecture & 3-Step Setup */}
        <Architecture />

        {/* Dedicated Package Downloads Section */}
        <Downloads
          latestRelease={latestRelease}
          isLoading={isLoadingRelease}
          onRefresh={fetchGitHubData}
          onDownload={handleDownload}
          androidAsset={androidAsset}
          windowsAsset={windowsAsset}
        />
      </main>

      {/* Footer & Contact Us */}
      <ContactFooter
        userEmail="lx00924@gmail.com"
        githubUrl={`https://github.com/${GITHUB_REPO}`}
      />
    </div>
  );
}
