import React, { useState } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { Trash2, X, Calendar, History, Trash, AlertCircle, ArrowLeft } from 'lucide-react';
import { Button } from '@/components/ui/button';

interface DeleteHistoryDialogProps {
  isOpen: boolean;
  onClose: () => void;
  onDeleteToday: () => void;
  onDeleteLast7Days: () => void;
  onDeleteAll: () => void;
}

type DeleteRange = 'today' | 'last7days' | 'all' | null;

export const DeleteHistoryDialog: React.FC<DeleteHistoryDialogProps> = ({
  isOpen,
  onClose,
  onDeleteToday,
  onDeleteLast7Days,
  onDeleteAll,
}) => {
  const [confirmRange, setConfirmRange] = useState<DeleteRange>(null);

  const handleConfirm = () => {
    if (confirmRange === 'today') onDeleteToday();
    if (confirmRange === 'last7days') onDeleteLast7Days();
    if (confirmRange === 'all') onDeleteAll();
    setConfirmRange(null);
    onClose();
  };

  const getRangeText = () => {
    if (confirmRange === 'today') return '今天';
    if (confirmRange === 'last7days') return '近 7 天';
    if (confirmRange === 'all') return '所有';
    return '';
  };

  // Reset state when dialog closes
  React.useEffect(() => {
    if (!isOpen) setConfirmRange(null);
  }, [isOpen]);

  return (
    <AnimatePresence>
      {isOpen && (
        <>
          {/* Backdrop */}
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            onClick={onClose}
            className="fixed inset-0 bg-black/40 backdrop-blur-sm z-[100]"
          />
          
          {/* Dialog Container */}
          <div className="fixed inset-0 flex items-center justify-center z-[101] pointer-events-none">
            <motion.div
              initial={{ opacity: 0, scale: 0.95, y: 20 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              exit={{ opacity: 0, scale: 0.95, y: 20 }}
              className="w-full max-w-md mx-4 bg-sidebar border shadow-2xl rounded-3xl overflow-hidden pointer-events-auto"
            >
              <div className="p-6">
                <AnimatePresence mode="wait">
                  {!confirmRange ? (
                    <motion.div
                      key="selection-view"
                      initial={{ opacity: 0, x: -20 }}
                      animate={{ opacity: 1, x: 0 }}
                      exit={{ opacity: 0, x: 20 }}
                    >
                      <div className="flex items-center justify-between mb-8">
                        <div className="flex items-center gap-3">
                          <div className="w-10 h-10 rounded-2xl bg-destructive/10 flex items-center justify-center text-destructive">
                            <Trash2 size={20} />
                          </div>
                          <div>
                            <h2 className="text-lg font-semibold">清理聊天记录</h2>
                            <p className="text-xs text-muted-foreground">选择要删除的时间范围</p>
                          </div>
                        </div>
                        <Button variant="ghost" size="icon" onClick={onClose} className="rounded-full">
                          <X size={18} />
                        </Button>
                      </div>

                      <div className="space-y-3">
                        <button
                          onClick={() => setConfirmRange('today')}
                          className="w-full flex items-center gap-4 p-4 rounded-2xl bg-muted/50 hover:bg-muted border border-transparent hover:border-muted-foreground/10 transition-all group text-left"
                        >
                          <div className="w-10 h-10 rounded-xl bg-background flex items-center justify-center text-muted-foreground group-hover:text-primary transition-colors">
                            <Calendar size={18} />
                          </div>
                          <div className="flex-1">
                            <div className="font-medium text-sm">删除今天</div>
                            <div className="text-[10px] text-muted-foreground">仅清除今日产生的对话内容</div>
                          </div>
                        </button>

                        <button
                          onClick={() => setConfirmRange('last7days')}
                          className="w-full flex items-center gap-4 p-4 rounded-2xl bg-muted/50 hover:bg-muted border border-transparent hover:border-muted-foreground/10 transition-all group text-left"
                        >
                          <div className="w-10 h-10 rounded-xl bg-background flex items-center justify-center text-muted-foreground group-hover:text-primary transition-colors">
                            <History size={18} />
                          </div>
                          <div className="flex-1">
                            <div className="font-medium text-sm">删除近 7 天</div>
                            <div className="text-[10px] text-muted-foreground">清除过去一周的所有聊天记录</div>
                          </div>
                        </button>

                        <button
                          onClick={() => setConfirmRange('all')}
                          className="w-full flex items-center gap-4 p-4 rounded-2xl bg-destructive/5 hover:bg-destructive/10 border border-transparent hover:border-destructive/20 transition-all group text-left"
                        >
                          <div className="w-10 h-10 rounded-xl bg-background flex items-center justify-center text-destructive/70 group-hover:text-destructive transition-colors">
                            <Trash size={18} />
                          </div>
                          <div className="flex-1">
                            <div className="font-medium text-sm text-destructive/90 group-hover:text-destructive">删除所有记录</div>
                            <div className="text-[10px] text-destructive/60">彻底清空所有历史对话，不可恢复</div>
                          </div>
                        </button>
                      </div>

                      <div className="mt-8 flex justify-end">
                        <Button variant="ghost" onClick={onClose} className="text-xs">
                          取消
                        </Button>
                      </div>
                    </motion.div>
                  ) : (
                    <motion.div
                      key="confirmation"
                      initial={{ opacity: 0, x: 20 }}
                      animate={{ opacity: 1, x: 0 }}
                      exit={{ opacity: 0, x: -20 }}
                      className="text-center py-4"
                    >
                      <div className="w-16 h-16 rounded-3xl bg-destructive/10 flex items-center justify-center text-destructive mx-auto mb-6">
                        <AlertCircle size={32} />
                      </div>
                      <h2 className="text-xl font-bold mb-2">确认删除？</h2>
                      <p className="text-sm text-muted-foreground mb-8">
                        你确定要删除 <span className="text-foreground font-semibold underline decoration-destructive/30 decoration-2 underline-offset-4">{getRangeText()}</span> 的聊天记录吗？<br />
                        此操作将无法撤销。
                      </p>
                      
                      <div className="grid grid-cols-2 gap-3">
                        <Button 
                          variant="ghost" 
                          onClick={() => setConfirmRange(null)}
                          className="rounded-2xl h-12 flex items-center justify-center gap-2"
                        >
                          <ArrowLeft size={16} />
                          返回
                        </Button>
                        <Button 
                          variant="destructive" 
                          onClick={handleConfirm}
                          className="rounded-2xl h-12 font-semibold shadow-lg shadow-destructive/20"
                        >
                          确认删除
                        </Button>
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </div>
            </motion.div>
          </div>
        </>
      )}
    </AnimatePresence>
  );
};
