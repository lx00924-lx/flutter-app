/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Rocket, Download, ExternalLink } from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import { safeSaveToLocalStorage } from '@/lib/utils';

interface UpdateDialogProps {
  isOpen: boolean;
  onClose: () => void;
  version: string;
  changelog: string;
  downloadUrl: string;
  onUpdate?: () => void;
  isUpdating?: boolean;
  progress?: number;
  platformType?: 'windows' | 'android' | 'web';
  targetFileName?: string;
}

export const UpdateDialog: React.FC<UpdateDialogProps> = ({
  isOpen,
  onClose,
  version,
  changelog,
  downloadUrl,
  onUpdate,
  isUpdating = false,
  progress = 0,
  platformType = 'android',
  targetFileName,
}) => {
  return (
    <Dialog open={isOpen} onOpenChange={(open) => !isUpdating && !open && onClose()}>
      <DialogContent 
        className="sm:max-w-[450px] bg-white dark:bg-card border-border text-foreground z-[9999]"
      >
        <DialogHeader>
          <div className="flex items-center gap-3 mb-2">
            <div className="p-2 rounded-xl bg-primary/10 text-primary">
              <Rocket size={20} />
            </div>
            <DialogTitle className="text-xl">
              发现新版本！
            </DialogTitle>
          </div>
          <div className="flex items-center gap-2">
            <DialogDescription className="text-sm font-medium text-primary">
              最新版本: {version}
            </DialogDescription>
            <span className="text-[10px] px-2 py-0.5 rounded-full font-semibold bg-primary/10 text-primary border border-primary/20">
              {platformType === 'windows' ? 'Windows 安装包 (.exe)' : platformType === 'android' ? 'Android 安装包 (.apk)' : 'Web/通用'}
            </span>
          </div>
        </DialogHeader>
        
        <div className="my-4 max-h-[40vh] overflow-y-auto pr-2 custom-scrollbar">
          <div className="text-xs text-muted-foreground mb-2 font-semibold uppercase tracking-wider">更新日志</div>
          <div className="markdown-body prose prose-sm dark:prose-invert max-w-none text-xs bg-muted/30 p-4 rounded-2xl border border-muted-foreground/10">
            <ReactMarkdown>{changelog || '该版本暂无详细描述。'}</ReactMarkdown>
          </div>
        </div>

        {isUpdating && (
          <div className="mb-4 space-y-1.5">
            <div className="flex justify-between text-xs text-muted-foreground">
              <span>{progress > 0 ? `下载进度 ${progress}%` : '正在下载更新包...'}</span>
              <span>{progress > 0 ? `${progress}%` : '请稍候'}</span>
            </div>
            <div className="h-2 w-full bg-muted rounded-full overflow-hidden">
              <div 
                className="h-full bg-primary transition-all duration-300 ease-out" 
                style={{ width: `${Math.max(5, progress)}%` }}
              />
            </div>
            <p className="text-[11px] text-center text-muted-foreground pt-1">
              {platformType === 'windows' ? '下载完成后将自动启动 Windows 安装程序' : '下载完成后将自动调起系统安装器'}
            </p>
          </div>
        )}

        <DialogFooter className="flex gap-2 sm:gap-0">
          {!isUpdating && (
            <Button variant="ghost" onClick={onClose} className="flex-1 rounded-xl h-11">
              以后再说
            </Button>
          )}
          <Button 
            className="flex-1 rounded-xl h-11 bg-primary text-primary-foreground shadow-lg shadow-primary/20 hover:opacity-90 disabled:opacity-50"
            disabled={isUpdating}
            onClick={() => {
              if (onUpdate) {
                onUpdate();
              } else {
                safeSaveToLocalStorage('app_version', version);
                window.location.reload();
              }
            }}
          >
            {isUpdating ? '正在下载更新...' : (
              <>
                <Rocket size={16} className="mr-2" />
                立即更新
              </>
            )}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};
